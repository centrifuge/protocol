// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISnapshotQueue, ShareQueueAmount, AssetQueueAmount} from "./interfaces/ISnapshotQueue.sol";

import {Auth} from "../../misc/Auth.sol";

import {ISpokeMessageSender} from "../messaging/interfaces/IGatewaySenders.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";

/// @title  SnapshotQueue
/// @notice Bookkeeping of the queued share and asset deltas each pool accumulates before they are
///         submitted to the Hub. Share deltas are netted per share class, asset flows are accumulated
///         gross per asset; flushing consumes a queue and returns the update payload for the Hub.
contract SnapshotQueue is Auth, ISnapshotQueue {
    mapping(PoolId => mapping(ShareClassId => ShareQueueAmount)) public queuedShares;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => AssetQueueAmount))) public queuedAssets;

    constructor(address deployer) Auth(deployer) {}

    //----------------------------------------------------------------------------------------------
    // Queue updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISnapshotQueue
    function queueAssets(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 amount, bool isIncrease)
        external
        auth
    {
        if (amount == 0) return;

        ShareQueueAmount storage shareQueue = queuedShares[poolId][scId];
        AssetQueueAmount storage assetQueue = queuedAssets[poolId][scId][assetId];
        if (assetQueue.deposits == 0 && assetQueue.withdrawals == 0) shareQueue.queuedAssetCounter++;

        if (isIncrease) assetQueue.deposits += amount;
        else assetQueue.withdrawals += amount;

        emit QueueAssets(poolId, scId, assetId, amount, isIncrease);
    }

    /// @inheritdoc ISnapshotQueue
    function queueShares(PoolId poolId, ShareClassId scId, uint128 shares, bool isIssuance) external auth {
        if (shares == 0) return;

        ShareQueueAmount storage shareQueue = queuedShares[poolId][scId];
        (shareQueue.delta, shareQueue.isPositive) =
            _netShares(shareQueue.delta, shareQueue.isPositive, shares, isIssuance);

        emit QueueShares(poolId, scId, shares, isIssuance);
    }

    //----------------------------------------------------------------------------------------------
    // Flushing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISnapshotQueue
    function flushAssets(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        auth
        returns (ISpokeMessageSender.UpdateData memory data)
    {
        AssetQueueAmount storage assetQueue = queuedAssets[poolId][scId][assetId];
        ShareQueueAmount storage shareQueue = queuedShares[poolId][scId];

        uint32 assetCounter = (assetQueue.deposits != 0 || assetQueue.withdrawals != 0) ? 1 : 0;

        data = ISpokeMessageSender.UpdateData({
            netAmount: (assetQueue.deposits >= assetQueue.withdrawals)
                ? assetQueue.deposits - assetQueue.withdrawals
                : assetQueue.withdrawals - assetQueue.deposits,
            isIncrease: assetQueue.deposits > assetQueue.withdrawals,
            isSnapshot: shareQueue.delta == 0 && shareQueue.queuedAssetCounter == assetCounter,
            nonce: shareQueue.nonce
        });

        assetQueue.deposits = 0;
        assetQueue.withdrawals = 0;
        shareQueue.nonce++;
        shareQueue.queuedAssetCounter -= assetCounter;

        emit SubmitQueuedAssets(poolId, scId, assetId, data);
    }

    /// @inheritdoc ISnapshotQueue
    function flushShares(PoolId poolId, ShareClassId scId)
        external
        auth
        returns (ISpokeMessageSender.UpdateData memory data)
    {
        ShareQueueAmount storage shareQueue = queuedShares[poolId][scId];

        data = ISpokeMessageSender.UpdateData({
            netAmount: shareQueue.delta,
            isIncrease: shareQueue.isPositive,
            isSnapshot: shareQueue.queuedAssetCounter == 0,
            nonce: shareQueue.nonce
        });

        shareQueue.delta = 0;
        shareQueue.isPositive = false;
        shareQueue.nonce++;

        emit SubmitQueuedShares(poolId, scId, data);
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    /// @dev Apply a signed share delta to the queued net (issuance adds, revocation subtracts) and return the
    ///      new magnitude and sign, computed once. The net is stored as a magnitude with a sign; a zero
    ///      magnitude is canonicalized to non-positive.
    function _netShares(uint128 delta, bool isPositive, uint128 shares, bool isIssuance)
        internal
        pure
        returns (uint128 newDelta, bool newIsPositive)
    {
        if (isIssuance == isPositive || delta == 0) {
            newDelta = delta + shares;
            newIsPositive = newDelta != 0 && isIssuance;
        } else if (delta >= shares) {
            newDelta = delta - shares;
            newIsPositive = newDelta != 0 && isPositive;
        } else {
            newDelta = shares - delta;
            newIsPositive = isIssuance;
        }
    }
}
