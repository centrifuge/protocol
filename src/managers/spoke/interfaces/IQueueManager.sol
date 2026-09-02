// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {AssetId} from "../../../core/types/AssetId.sol";
import {ISpoke} from "../../../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {IGateway} from "../../../core/messaging/interfaces/IGateway.sol";
import {ISnapshotQueue} from "../../../core/spoke/interfaces/ISnapshotQueue.sol";

/// @title  IQueueManager
/// @notice Interface for managing queued asset and share synchronization across chains
/// @dev    Handles delayed sync operations with configurable minimum delays and gas limits
interface IQueueManager {
    event UpdateQueueConfig(
        PoolId indexed poolId, ShareClassId indexed scId, uint64 newMinDelay, uint128 newExtraGasLimit
    );

    error NotEnvoy();
    error UnexpectedValue();
    error MinDelayNotElapsed();
    error NoUpdateForAsset();
    error InsufficientFunds();

    struct ShareClassQueueState {
        uint64 minDelay;
        uint64 lastSync;
        uint128 extraGasLimit;
    }

    /// @notice Routes and batches cross-chain messages between hub and spoke
    function gateway() external view returns (IGateway);

    /// @notice The Envoy that routes policy-supervised queue configuration updates
    function envoy() external view returns (address);

    /// @notice Manages share token and asset balances, including minting, burning, and escrow transfers
    function spoke() external view returns (ISpoke);

    /// @notice Stores the queued share and asset deltas pending submission to the hub
    function snapshotQueue() external view returns (ISnapshotQueue);

    /// @notice Queue configuration and timing state for a specific pool and share class
    /// @param poolId The pool ID
    /// @param scId The share class ID
    function scQueueState(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint64 minDelay, uint64 lastSync, uint128 extraGasLimit);

    /// @notice Sync queued assets and shares for a given pool and share class
    /// @param poolId the pool ID
    /// @param scId the share class ID
    /// @param assetIds the asset IDs to sync
    /// @dev It is the caller's responsibility to ensure all asset IDs have a non-zero delta,
    ///      and `sync` is called n times up until the moment all asset IDs are included, and the shares
    ///      get synced as well.
    function sync(PoolId poolId, ShareClassId scId, AssetId[] calldata assetIds, address refund) external payable;
}
