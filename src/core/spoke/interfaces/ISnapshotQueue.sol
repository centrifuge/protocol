// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISpokeMessageSender} from "../../messaging/interfaces/IGatewaySenders.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";

struct ShareQueueAmount {
    // Net queued shares
    uint128 delta;
    // Whether the net queued shares lead to an issuance or revocation
    bool isPositive;
    // Number of queued asset IDs for this share class
    uint32 queuedAssetCounter;
    // Nonce for share + asset messages to the hub
    uint64 nonce;
}

struct AssetQueueAmount {
    // Gross queued deposit amount (asset units)
    uint128 deposits;
    // Gross queued withdrawal amount (asset units)
    uint128 withdrawals;
}

interface ISnapshotQueue {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event QueueAssets(
        PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, uint128 amount, bool isIncrease
    );
    event QueueShares(PoolId indexed poolId, ShareClassId indexed scId, uint128 shares, bool isIssuance);
    event SubmitQueuedShares(PoolId indexed poolId, ShareClassId indexed scId, ISpokeMessageSender.UpdateData data);
    event SubmitQueuedAssets(
        PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, ISpokeMessageSender.UpdateData data
    );

    //----------------------------------------------------------------------------------------------
    // Queue updates
    //----------------------------------------------------------------------------------------------

    /// @notice Accumulate a gross asset flow into the queue.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param amount The asset amount (a zero amount is a no-op)
    /// @param isIncrease Whether the flow is a deposit (true) or a withdrawal (false)
    function queueAssets(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 amount, bool isIncrease) external;

    /// @notice Apply a share delta to the queued net (issuance adds, revocation subtracts).
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param shares The number of shares
    /// @param isIssuance Whether the delta is an issuance (true) or a revocation (false)
    function queueShares(PoolId poolId, ShareClassId scId, uint128 shares, bool isIssuance) external;

    //----------------------------------------------------------------------------------------------
    // Flushing
    //----------------------------------------------------------------------------------------------

    /// @notice Consume the queued asset flow, returning the net update to be sent to the Hub.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @return data The net queued amount, snapshot flag, and nonce for the Hub message
    function flushAssets(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        returns (ISpokeMessageSender.UpdateData memory data);

    /// @notice Consume the queued share delta, returning the net update to be sent to the Hub.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @return data The net queued shares, snapshot flag, and nonce for the Hub message
    function flushShares(PoolId poolId, ShareClassId scId) external returns (ISpokeMessageSender.UpdateData memory data);

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the queued shares for a share class
    function queuedShares(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint128 delta, bool isPositive, uint32 queuedAssetCounter, uint64 nonce);

    /// @notice Returns the queued assets for a share class and asset
    /// @return deposits Queued deposit amount
    /// @return withdrawals Queued withdrawal amount
    function queuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint128 deposits, uint128 withdrawals);
}
