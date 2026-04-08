// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IManifest} from "../interfaces/ISupervisor.sol";

import {D18} from "../../../misc/types/D18.sol";
import {IHub} from "../../../core/hub/interfaces/IHub.sol";
import {PoolId} from "../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {ITrustedContractUpdate} from "../../../core/utils/interfaces/IContractUpdate.sol";

/// @title  Share Price Delta Manifest
/// @notice Limits updateSharePrice to a maximum percentage change per rolling window.
///         Anchors to the first price submitted in each window. All subsequent updates within
///         the window are compared against that anchor.
contract SharePriceDeltaManifest is IManifest, ITrustedContractUpdate {
    struct Slot {
        uint128 anchor;      // First price in the current window
        uint64 windowStart;  // When the current window began
        uint64 window;       // Window duration in seconds
        uint128 maxDeltaBps; // Max deviation from anchor in bps
    }

    event SetConfig(PoolId indexed poolId, ShareClassId indexed scId, uint128 maxDeltaBps, uint64 window);

    error NotAuthorized();

    address public immutable contractUpdater;

    mapping(PoolId => mapping(ShareClassId => Slot)) public slots;

    constructor(address contractUpdater_) {
        contractUpdater = contractUpdater_;
    }

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(PoolId poolId, ShareClassId scId, bytes calldata payload) external {
        require(msg.sender == contractUpdater, NotAuthorized());
        (uint128 maxDeltaBps, uint64 window) = abi.decode(payload, (uint128, uint64));
        slots[poolId][scId] = Slot(0, 0, window, maxDeltaBps);
        emit SetConfig(poolId, scId, maxDeltaBps, window);
    }

    /// @inheritdoc IManifest
    function check(PoolId, address, bytes calldata data) external returns (bool) {
        if (bytes4(data[:4]) != IHub.updateSharePrice.selector) return true;

        (PoolId poolId, ShareClassId scId, D18 newPrice,) =
            abi.decode(data[4:], (PoolId, ShareClassId, D18, uint64));

        Slot storage s = slots[poolId][scId];
        if (s.maxDeltaBps == 0) return true;

        uint128 newVal = D18.unwrap(newPrice);

        if (s.windowStart == 0 || block.timestamp - s.windowStart > s.window) {
            s.anchor = newVal;
            s.windowStart = uint64(block.timestamp);
            return true;
        }

        uint256 anchor = s.anchor;
        uint256 delta = newVal > anchor ? newVal - anchor : anchor - newVal;
        return delta * 10_000 <= anchor * s.maxDeltaBps;
    }
}
