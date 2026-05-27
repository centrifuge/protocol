// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IStdManifest} from "./interfaces/IStdManifest.sol";
import {BytesLib} from "../../../misc/libraries/BytesLib.sol";
import {IShareClassManager} from "../../../core/hub/interfaces/IShareClassManager.sol";
import {IMultiAdapter} from "../../../core/messaging/interfaces/IMultiAdapter.sol";
import {IAdapter} from "../../../core/messaging/interfaces/IAdapter.sol";
import {IHub} from "../../../core/hub/interfaces/IHub.sol";
import {IManifest} from "../../../core/hub/interfaces/IManifest.sol";
import {IOnOfframpManager} from "../../spoke/interfaces/IOnOfframpManager.sol";

import {D18} from "../../../misc/types/D18.sol";
import {PoolId} from "../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";


/// @title  Standard Manifest
/// @notice Default manifest installed on the Hub via {IHub.setManifest}. Combines:
///         1. Asymmetric timelocks: granting manager access returns an additional delay,
///            revoking access passes through instantly.
///         2. Blocks removing the Supervisor itself as a Hub manager.
///         3. Rate-limits share price updates. If the price change per second exceeds a
///            threshold, a fixed timelock delay is returned.
///         4. Timelocks updateContract calls with TrustedCall.Onramp.
///         5. Enforces setAdapters uses exactly the global adapters (poolId=0).
///         6. Self-replacement is timelocked: any subsequent {setManifest} call waits
///            `timelock` seconds, so a compromised operator can't hot-swap the policy.
contract StdManifest is IStdManifest {
    using BytesLib for bytes;

    IHub public immutable hub;
    address public immutable supervisor;
    uint48 public immutable timelock;
    uint48 public immutable grantManagerDelay;
    uint128 public immutable thresholdPerSecond;
    IShareClassManager public immutable shareClassManager;
    IMultiAdapter public immutable multiAdapter;

    mapping(PoolId => mapping(ShareClassId => uint48)) public lastPriceUpdate;

    constructor(
        IHub hub_,
        address supervisor_,
        uint48 timelock_,
        uint48 grantManagerDelay_,
        uint128 thresholdPerSecond_,
        IShareClassManager shareClassManager_,
        IMultiAdapter multiAdapter_
    ) {
        hub = hub_;
        supervisor = supervisor_;
        timelock = timelock_;
        grantManagerDelay = grantManagerDelay_;
        thresholdPerSecond = thresholdPerSecond_;
        shareClassManager = shareClassManager_;
        multiAdapter = multiAdapter_;
    }

    //----------------------------------------------------------------------------------------------
    // Validation
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManifest
    function check(PoolId poolId, address, bytes calldata data) external returns (uint48) {
        require(msg.sender == address(hub), NotAuthorized());

        (bytes4 selector, bytes calldata payload) = data.decodeCall();
        if (selector == IHub.updateHubManager.selector) return _checkHubManager(payload);
        if (selector == IHub.updateSharePrice.selector) return _checkSharePrice(poolId, payload);
        if (selector == IHub.updateBalanceSheetManager.selector) return _checkBalanceSheetManager(payload);
        if (selector == IHub.updateContract.selector) return _checkUpdateContract(payload);
        if (selector == IHub.setAdapters.selector) return _checkSetAdapters(payload);
        // Manifest swap: enforce our timelock on our own replacement so a compromised operator
        // can't hot-swap the whole policy in one tx. First-time install is unaffected because
        // when no manifest is set Hub skips the check entirely.
        if (selector == IHub.setManifest.selector) return timelock;

        return 0;
    }

    /// @dev Blocks removing the Supervisor as a Hub manager; adds delay when granting access.
    function _checkHubManager(bytes calldata payload) internal view returns (uint48) {
        (, address who, bool canManage) = abi.decode(payload, (PoolId, address, bool));
        require(who != supervisor || canManage, CannotRemoveSupervisor());
        return canManage ? grantManagerDelay : 0;
    }

    /// @dev Blocks removing the Supervisor as a BalanceSheet manager; adds delay when granting access.
    function _checkBalanceSheetManager(bytes calldata payload) internal view returns (uint48) {
        (,, bytes32 who, bool canManage,) = abi.decode(payload, (PoolId, uint16, bytes32, bool, address));
        require(who != bytes32(bytes20(supervisor)) || canManage, CannotRemoveSupervisor());
        return canManage ? grantManagerDelay : 0;
    }

    /// @dev Adds timelock for two updateContract patterns: TrustedCall.Onramp on an OnOffRamp
    ///      manager, and ANY payload whose `target` is the Supervisor itself. The latter is
    ///      load-bearing — sentinel add/remove flows through `updateContract → ContractUpdater
    ///      → Supervisor.trustedCall`, and without this filter a compromised operator could
    ///      install attacker sentinels in one tx via `awaitAndExecute`.
    function _checkUpdateContract(bytes calldata payload) internal view returns (uint48) {
        (,,, bytes32 target, bytes memory innerPayload,,) =
            abi.decode(payload, (PoolId, ShareClassId, uint16, bytes32, bytes, uint128, address));
        if (target == bytes32(bytes20(supervisor))) return grantManagerDelay;
        uint8 kind = abi.decode(innerPayload, (uint8));
        return kind == uint8(IOnOfframpManager.TrustedCall.Onramp) ? grantManagerDelay : 0;
    }

    /// @dev Reverts if localAdapters don't match the global adapters (poolId=0) for the given centrifugeId.
    function _checkSetAdapters(bytes calldata payload) internal view returns (uint48) {
        (, uint16 centrifugeId, IAdapter[] memory localAdapters,,,,) =
            abi.decode(payload, (PoolId, uint16, IAdapter[], bytes32[], uint8, uint8, address));

        PoolId globalPool = PoolId.wrap(0);
        uint8 quorum = multiAdapter.quorum(centrifugeId, globalPool);
        require(localAdapters.length == quorum, AdapterMismatch());

        for (uint256 i; i < quorum; i++) {
            require(localAdapters[i] == multiAdapter.adapters(centrifugeId, globalPool, i), AdapterMismatch());
        }

        return 0;
    }

    /// @dev Returns timelock delay if the price change per second exceeds the threshold.
    ///
    ///      Interleaving attack: An operator can submit N compliant intermediate price updates
    ///      (each just below the threshold) to achieve a cumulative move of up to N * threshold * elapsed.
    ///      Each intermediate update resets `lastPriceUpdate`, so the next step is measured from a fresh
    ///      baseline. The maximum undetected move per step is `thresholdPerSecond * elapsed - 1`, bounded
    ///      by the timelock delay between submissions. Sentinels can veto any suspicious sequence.
    function _checkSharePrice(PoolId poolId, bytes calldata payload) internal returns (uint48) {
        (, ShareClassId scId, D18 newPrice,) = abi.decode(payload, (PoolId, ShareClassId, D18, uint64));

        if (thresholdPerSecond == 0) return 0;

        (D18 lastPrice,) = shareClassManager.pricePoolPerShare(poolId, scId);
        uint48 lastUpdate = lastPriceUpdate[poolId][scId];
        lastPriceUpdate[poolId][scId] = uint48(block.timestamp);

        if (lastUpdate == 0) return 0;

        uint256 elapsed = block.timestamp - lastUpdate;
        if (elapsed == 0) elapsed = 1;

        uint128 newRaw = D18.unwrap(newPrice);
        uint128 lastRaw = D18.unwrap(lastPrice);
        uint256 delta = newRaw > lastRaw ? newRaw - lastRaw : lastRaw - newRaw;

        if (delta / elapsed >= thresholdPerSecond) {
            return timelock;
        }
        return 0;
    }
}
