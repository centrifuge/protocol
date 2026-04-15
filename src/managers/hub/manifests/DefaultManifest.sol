// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IDefaultManifest, PriceDeltaSlot} from "./interfaces/IDefaultManifest.sol";

import {D18} from "../../../misc/types/D18.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {IHub} from "../../../core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {ITrustedContractUpdate} from "../../../core/utils/interfaces/IContractUpdate.sol";

import {IManifest} from "../interfaces/ISupervisor.sol";

/// @title  Default Manifest
/// @notice Combined manifest providing:
///         1. Share price delta limits per rolling window
///         2. Asymmetric timelocks: granting manager access returns an additional delay,
///            revoking access passes through instantly
///         3. Blocks removing the Supervisor itself as a Hub manager
contract DefaultManifest is IDefaultManifest {
    address public immutable supervisor;
    address public immutable contractUpdater;
    uint48 public immutable grantManagerDelay;

    mapping(PoolId => mapping(ShareClassId => PriceDeltaSlot)) public priceDeltaSlots;

    constructor(address supervisor_, address contractUpdater_, uint48 grantManagerDelay_) {
        supervisor = supervisor_;
        contractUpdater = contractUpdater_;
        grantManagerDelay = grantManagerDelay_;
    }

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(PoolId poolId, ShareClassId scId, bytes calldata payload) external {
        require(msg.sender == contractUpdater, NotAuthorized());
        (uint128 maxDeltaBps, uint64 window) = abi.decode(payload, (uint128, uint64));
        priceDeltaSlots[poolId][scId] = PriceDeltaSlot(0, 0, window, maxDeltaBps);
        emit SetPriceDeltaConfig(poolId, scId, maxDeltaBps, window);
    }

    /// @inheritdoc IManifest
    function check(PoolId, address, bytes calldata data) external returns (uint48) {
        require(msg.sender == supervisor, NotAuthorized());

        bytes4 selector = bytes4(data[:4]);

        if (selector == IHub.updateSharePrice.selector) return _checkPriceDelta(data);
        if (selector == IHub.updateHubManager.selector) return _checkHubManager(data);
        if (selector == IHub.updateBalanceSheetManager.selector) return _checkBalanceSheetManager(data);

        return 0;
    }

    //----------------------------------------------------------------------------------------------
    // Share price delta
    //----------------------------------------------------------------------------------------------

    function _checkPriceDelta(bytes calldata data) internal returns (uint48) {
        (PoolId poolId, ShareClassId scId, D18 newPrice,) =
            abi.decode(data[4:], (PoolId, ShareClassId, D18, uint64));

        PriceDeltaSlot storage s = priceDeltaSlots[poolId][scId];
        if (s.maxDeltaBps == 0) return 0;

        uint128 newVal = D18.unwrap(newPrice);

        // Always check delta against anchor (even at window boundary)
        if (s.anchor != 0) {
            uint256 anchor = s.anchor;
            uint256 delta = newVal > anchor ? newVal - anchor : anchor - newVal;
            require(delta * 10_000 <= anchor * s.maxDeltaBps, DeltaExceeded(anchor, newVal, s.maxDeltaBps));
        }

        // Reset window if expired or first update
        if (s.windowStart == 0 || block.timestamp - s.windowStart > s.window) {
            s.anchor = newVal;
            s.windowStart = uint64(block.timestamp);
        }

        return 0;
    }

    //----------------------------------------------------------------------------------------------
    // Asymmetric manager timelocks
    //----------------------------------------------------------------------------------------------

    function _checkHubManager(bytes calldata data) internal view returns (uint48) {
        (, address who, bool canManage) = abi.decode(data[4:], (PoolId, address, bool));
        require(who != supervisor || canManage, CannotRemoveSupervisor());
        return canManage ? grantManagerDelay : 0;
    }

    function _checkBalanceSheetManager(bytes calldata data) internal view returns (uint48) {
        (,, bytes32 who, bool canManage,) = abi.decode(data[4:], (PoolId, uint16, bytes32, bool, address));
        require(who != bytes32(bytes20(supervisor)) || canManage, CannotRemoveSupervisor());
        return canManage ? grantManagerDelay : 0;
    }
}
