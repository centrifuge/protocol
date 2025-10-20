// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {AssetId} from "../../../core/types/AssetId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";

/// @title  IQueueManager
/// @notice Interface for managing queued asset and share synchronization across chains
/// @dev    Handles delayed sync operations with configurable minimum delays and gas limits
interface IQueueManager {
    event UpdateQueueConfig(
        PoolId indexed poolId, ShareClassId indexed scId, uint64 newMinDelay, uint128 newExtraGasLimit
    );

    error NotContractUpdater();
    error MinDelayNotElapsed();
    error NoUpdateForAsset();
    error InsufficientFunds();

    struct ShareClassQueueState {
        uint64 minDelay;
        uint64 lastSync;
        uint128 extraGasLimit;
    }

    /// @notice Sync queued assets and shares for a given pool and share class
    /// @param poolId the pool ID
    /// @param scId the share class ID
    /// @param assetIds the asset IDs to sync
    /// @dev It is the caller's responsibility to ensure all asset IDs have a non-zero delta,
    ///      and `sync` is called n times up until the moment all asset IDs are included, and the shares
    ///      get synced as well.
    function sync(PoolId poolId, ShareClassId scId, AssetId[] calldata assetIds, address refund) external payable;
}
