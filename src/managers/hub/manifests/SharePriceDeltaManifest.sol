// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IManifestHook} from "../interfaces/ISupervisor.sol";

import {D18} from "../../../misc/types/D18.sol";
import {IHub} from "../../../core/hub/interfaces/IHub.sol";
import {PoolId} from "../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {ITrustedContractUpdate} from "../../../core/utils/interfaces/IContractUpdate.sol";

/// @title  Share Price Delta Manifest
/// @notice Manifest hook that limits updateSharePrice to a maximum percentage change per rolling window.
///         Anchors to the current on-chain price at the start of each window. All updates within the
///         window are compared against that fixed anchor, preventing death-by-a-thousand-cuts.
///
///         Configuration is managed via trustedCall from the ContractUpdater, so config changes
///         go through the Supervisor's timelock if updateContract is timelocked.
contract SharePriceDeltaManifest is IManifestHook, ITrustedContractUpdate {
    struct Config {
        uint128 maxDeltaBps;
        uint64 window;
    }

    struct State {
        uint128 anchor;
        uint64 windowStart;
    }

    event SetConfig(PoolId indexed poolId, ShareClassId indexed scId, uint128 maxDeltaBps, uint64 window);

    error NotAuthorized();

    IHub public immutable hub;
    address public immutable contractUpdater;

    mapping(PoolId => mapping(ShareClassId => Config)) public config;
    mapping(PoolId => mapping(ShareClassId => State)) public state;

    constructor(IHub hub_, address contractUpdater_) {
        hub = hub_;
        contractUpdater = contractUpdater_;
    }

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(PoolId poolId, ShareClassId scId, bytes calldata payload) external {
        require(msg.sender == contractUpdater, NotAuthorized());
        (uint128 maxDeltaBps, uint64 window) = abi.decode(payload, (uint128, uint64));
        config[poolId][scId] = Config(maxDeltaBps, window);
        delete state[poolId][scId];
        emit SetConfig(poolId, scId, maxDeltaBps, window);
    }

    /// @inheritdoc IManifestHook
    function check(PoolId, address, bytes calldata data) external returns (bool) {
        if (bytes4(data[:4]) != IHub.updateSharePrice.selector) return true;

        (PoolId poolId, ShareClassId scId, D18 newPrice,) =
            abi.decode(data[4:], (PoolId, ShareClassId, D18, uint64));

        Config memory cfg = config[poolId][scId];
        if (cfg.maxDeltaBps == 0) return true;

        State storage s = state[poolId][scId];
        uint256 anchor;

        if (s.windowStart == 0 || block.timestamp - s.windowStart > cfg.window) {
            (D18 currentPrice,) = hub.shareClassManager().pricePoolPerShare(poolId, scId);
            anchor = D18.unwrap(currentPrice);
            s.anchor = uint128(anchor);
            s.windowStart = uint64(block.timestamp);
        } else {
            anchor = s.anchor;
        }

        if (anchor == 0) return true;

        uint256 newVal = D18.unwrap(newPrice);
        uint256 delta = newVal > anchor ? newVal - anchor : anchor - newVal;
        return delta * 10_000 <= anchor * cfg.maxDeltaBps;
    }
}
