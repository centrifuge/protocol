// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IPriceManifest} from "./interfaces/IPriceManifest.sol";
import {BytesLib} from "../../../misc/libraries/BytesLib.sol";
import {IShareClassManager} from "../../../core/hub/interfaces/IShareClassManager.sol";
import {IHub} from "../../../core/hub/interfaces/IHub.sol";
import {IManifest} from "../interfaces/ISupervisor.sol";

import {D18} from "../../../misc/types/D18.sol";
import {PoolId} from "../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";


/// @title  Price Manifest
/// @notice Default manifest for Supervisors, combining:
///         1. Asymmetric timelocks: granting manager access returns an additional delay,
///            revoking access passes through instantly.
///         2. Blocks removing the Supervisor itself as a Hub manager.
///         3. Rate-limits share price updates. If the price change per second exceeds a
///            threshold, a fixed escalation delay is returned.
contract PriceManifest is IPriceManifest {
    using BytesLib for bytes;
    
    address public immutable supervisor;
    uint48 public immutable escalation;
    uint48 public immutable grantManagerDelay;
    uint128 public immutable thresholdPerSecond;
    IShareClassManager public immutable shareClassManager;

    mapping(PoolId => mapping(ShareClassId => uint48)) public lastPriceUpdate;

    constructor(
        address supervisor_,
        uint48 escalation_,
        uint48 grantManagerDelay_,
        uint128 thresholdPerSecond_,
        IShareClassManager shareClassManager_
    ) {
        supervisor = supervisor_;
        escalation = escalation_;
        grantManagerDelay = grantManagerDelay_;
        thresholdPerSecond = thresholdPerSecond_;
        shareClassManager = shareClassManager_;
    }

    //----------------------------------------------------------------------------------------------
    // Validation
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManifest
    function check(PoolId poolId, address, bytes calldata data) external returns (uint48) {
        require(msg.sender == supervisor, NotAuthorized());

        (bytes4 selector, bytes calldata payload) = data.decodeCall();
        if (selector == IHub.updateHubManager.selector) return _checkHubManager(payload);
        if (selector == IHub.updateSharePrice.selector) return _checkSharePrice(poolId, payload);
        if (selector == IHub.updateBalanceSheetManager.selector) return _checkBalanceSheetManager(payload);

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

    /// @dev Returns escalation delay if the price change per second exceeds the threshold.
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
            return escalation;
        }
        return 0;
    }
}
