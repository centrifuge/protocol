// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId, newShareClassId} from "src/common/types/ShareClassId.sol";

import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {
    IShareClassManager,
    EpochAmounts,
    UserOrder,
    EpochPointers,
    ShareClassMetadata,
    ShareClassMetrics,
    QueuedOrder,
    RequestType
} from "src/hub/interfaces/IShareClassManager.sol";

contract ShareClassManager is Auth, IShareClassManager {
    using MathLib for *;
    using CastLib for *;
    using BytesLib for bytes;

    uint32 constant META_NAME_LENGTH = 128;
    uint32 constant META_SYMBOL_LENGTH = 32;

    IHubRegistry public hubRegistry;

    mapping(bytes32 salt => bool) public salts;
    mapping(ShareClassId scId => mapping(AssetId assetId => uint32)) public investEpochId;
    mapping(ShareClassId scId => mapping(AssetId assetId => uint32)) public issueEpochId;
    mapping(ShareClassId scId => mapping(AssetId assetId => uint32)) public redeemEpochId;
    mapping(ShareClassId scId => mapping(AssetId assetId => uint32)) public revokeEpochId;

    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(uint32 epochId_ => EpochInvestAmounts epoch)))
        public epochInvestAmounts;
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(uint32 epochId_ => EpochRedeemAmounts epoch)))
        public epochRedeemAmounts;

    mapping(PoolId poolId => uint32) public shareClassCount;
    mapping(ShareClassId scId => ShareClassMetrics) public metrics;
    mapping(ShareClassId scId => ShareClassMetadata) public metadata;
    mapping(PoolId poolId => mapping(ShareClassId => bool)) public shareClassIds;

    mapping(ShareClassId scId => mapping(AssetId payoutAssetId => uint128 pending)) public pendingRedeem;
    mapping(ShareClassId scId => mapping(AssetId paymentAssetId => uint128 pending)) public pendingDeposit;

    mapping(ShareClassId scId => mapping(AssetId payoutAssetId => mapping(bytes32 investor => UserOrder pending)))
        public redeemRequest;
    mapping(ShareClassId scId => mapping(AssetId paymentAssetId => mapping(bytes32 investor => UserOrder pending)))
        public depositRequest;
    mapping(ShareClassId scId => mapping(AssetId payoutAssetId => mapping(bytes32 investor => QueuedOrder queued)))
        public queuedRedeemRequest;
    mapping(ShareClassId scId => mapping(AssetId paymentAssetId => mapping(bytes32 investor => QueuedOrder queued)))
        public queuedDepositRequest;

    constructor(IHubRegistry hubRegistry_, address deployer) Auth(deployer) {
        hubRegistry = hubRegistry_;
    }

    function file(bytes32 what, address data) external auth {
        require(what == "hubRegistry", UnrecognizedFileParam());
        hubRegistry = IHubRegistry(data);
        emit File(what, data);
    }

    /// @inheritdoc IShareClassManager
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes32 salt, bytes calldata)
        external
        auth
        returns (ShareClassId scId_)
    {
        scId_ = previewNextShareClassId(poolId);

        uint32 index = ++shareClassCount[poolId];
        shareClassIds[poolId][scId_] = true;

        _updateMetadata(scId_, name, symbol, salt);

        emit AddShareClass(poolId, scId_, index, name, symbol, salt);
    }

    /// @inheritdoc IShareClassManager
    function requestDeposit(PoolId poolId, ShareClassId scId_, uint128 amount, bytes32 investor, AssetId depositAssetId)
        external
        auth
    {
        require(exists(poolId, scId_), ShareClassNotFound());

        // NOTE: CV ensures amount > 0
        _updatePending(poolId, scId_, amount, true, investor, depositAssetId, RequestType.Deposit);
    }

    function cancelDepositRequest(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId depositAssetId)
        external
        auth
        returns (uint128 cancelledAssetAmount)
    {
        require(exists(poolId, scId_), ShareClassNotFound());

        uint128 cancellingAmount = depositRequest[scId_][depositAssetId][investor].pending;

        return _updatePending(poolId, scId_, cancellingAmount, false, investor, depositAssetId, RequestType.Deposit);
    }

    /// @inheritdoc IShareClassManager
    function requestRedeem(PoolId poolId, ShareClassId scId_, uint128 amount, bytes32 investor, AssetId payoutAssetId)
        external
        auth
    {
        require(exists(poolId, scId_), ShareClassNotFound());

        // NOTE: CV ensures amount > 0
        _updatePending(poolId, scId_, amount, true, investor, payoutAssetId, RequestType.Redeem);
    }

    /// @inheritdoc IShareClassManager
    function cancelRedeemRequest(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId payoutAssetId)
        external
        auth
        returns (uint128 cancelledShareAmount)
    {
        require(exists(poolId, scId_), ShareClassNotFound());

        uint128 cancellingAmount = redeemRequest[scId_][payoutAssetId][investor].pending;

        return _updatePending(poolId, scId_, cancellingAmount, false, investor, payoutAssetId, RequestType.Redeem);
    }

    /// @inheritdoc IShareClassManager
    function approveDeposits(
        PoolId poolId,
        ShareClassId scId_,
        uint128 approvedAssetAmount,
        AssetId paymentAssetId,
        D18 pricePoolPerAsset
    ) external auth returns (uint128 approvedAssetAmount, uint128 approvedPoolAmount) {
        require(exists(poolId, scId_), ShareClassNotFound());
        uint32 epochId = investEpochId[poolId][paymentAssetId] + 1;
        emit NewInvestEpoch(epochId, paymentAssetId);

        // Limit in case approved > pending due to race condition of FM approval and async incoming requests
        uint128 pendingAssetAmount = pendingDeposit[scId_][paymentAssetId];
        require(approvedAssetAmount <= pendingAssetAmount, NotEnoughPending());
        require(approvedAssetAmount > 0, ZeroApprovalAmount());

        // Update epoch data
        EpochInvestAmounts storage epochAmounts_ = epochInvestAmounts[scId_][paymentAssetId][epochId];
        epochAmounts_.approvedAssetAmount = approvedAssetAmount;
        eppchAmounts_.approvedPoolAmount = ConversionLib.convertWithPrice(approvedAssetAmount, asset, pool, pricePoolPerAsset);
        epochAmounts_.pendingAssetAmount = pendingAssetAmount;

        // Reduce pending
        pendingDeposit[scId_][paymentAssetId] -= approvedAssetAmount;
        investEpochId[poolId][paymentAssetId] = epochId;
        pendingAssetAmount -= approvedAssetAmount;

        emit ApproveDeposits(
            poolId, scId_, epochId, paymentAssetId, approvedPoolAmount, approvedAssetAmount, pendingAssetAmount
        );
    }

    /// @inheritdoc IShareClassManager
    function approveRedeems(PoolId poolId, ShareClassId scId_, uint128 approvedShareAmount, AssetId payoutAssetId)
        external
        auth
        returns (uint128 approvedShareAmount, uint128 pendingShareAmount)
    {
        require(exists(poolId, scId_), ShareClassNotFound());
        uint32 epochId = investEpochId[poolId][paymentAssetId] + 1;
        emit NewRedeemEpoch(epochId, paymentAssetId);

        // Limit in case approved > pending due to race condition of FM approval and async incoming requests
        pendingShareAmount = pendingRedeem[scId_][payoutAssetId];
        require(approvedShareAmount <= pendingShareAmount, NotEnoughPending());
        require(approvedShareAmount > 0, ZeroApprovalAmount());

        // Update epoch data
        EpochRedeemAmounts storage epochAmounts = epochRedeemAmounts[scId_][payoutAssetId][epochId];
        epochAmounts.approvedShareAmount = approvedShareAmount;
        epochAmounts.pendingShareAmount = pendingShareAmount;

        // Reduce pending
        pendingRedeem[scId_][payoutAssetId] -= approvedShareAmount;
        pendingShareAmount -= approvedShareAmount;

        emit ApproveRedeems(poolId, scId_, approvalEpochId, payoutAssetId, approvedShareAmount, pendingShareAmount);
    }

    /// @inheritdoc IShareClassManager
    function issueShares(
        PoolId poolId,
        ShareClassId scId_,
        AssetId depositAssetId,
        D18 navPoolPerShare,
        uint32 epochId
    ) public auth {
        require(exists(poolId, scId_), ShareClassNotFound());
        require(investEpochId[scId_][depositAssetId][epochId] != 0, EpochNotFound());
        require(issueEpochId[scId_][depositAssetId][epochId] < epochId, AlreadyIssued());

        EpochInvestAmount storage epochAmounts = epochInvestAmounts[scId_][depositAssetId][epochId];

        //TODO: Calculate navAssetPerShare with approvedPoolAmount and approvedAssetAmount
        D18 navAssetPerShare = navPoolPerShare;
        uint128 issuedShareAmount =
            ConversionLib.convertWithPrice(epochAmounts.approvedAssetAmount, asset, pool, navAssetPerShare);
        metrics[scId_].totalIssuance += issuedShareAmount;
        epochAmounts.issuedAt = block.timestamp;
        issueEpochId[scId_][depositAssetId][epochId] += 1;

        emit IssueShares(poolId, scId_, epochId, navPoolPerShare, navAssetPerShare, issuedShareAmount);
    }

    /// @inheritdoc IShareClassManager
    function revokeShares(
        PoolId poolId,
        ShareClassId scId_,
        AssetId depositAssetId,
        D18 navPoolPerShare,
        D18 navAssetPerShare,
        uint32 epochId
    ) public auth {
        require(exists(poolId, scId_), ShareClassNotFound());
        require(redeemEpochId[scId_][depositAssetId][epochId] != 0, EpochNotFound());
        require(revokeEpochId[scId_][depositAssetId][epochId] < epochId, AlreadyRevoked());

        EpochRedeemAmount storage epochAmounts = epochRedeemAmounts[scId_][depositAssetId][epochId];

        require(epochAmounts.approvedShareAmounts <= metrics[scId_].totalIssuance, RevokeMoreThanIssued());

        uint128 payoutAssetAmount = ConversionLib.convertWithPrice(epochAmounts.approvedShareAmount, poolDecimals, assetDecimals, navAssetPerShare);
        // NOTE: shares and pool currency have the same decimals - no conversion needed!
        uint128 payoutPoolAmount = navPoolPerShare.mulUint128(epochAmounts.approvedShareAmounts);

        metrics[scId_].totalIssuance -= amounts.approvedShareAmounts;
        epochAmounts.payoutAssetAmount = payoutAssetAmount;
        epochAmounts.revokedAt = block.timestamp;
        revokeEpochId[scId_][depositAssetId][epochId] += 1;

        emit RevokeShares(poolId, scId_, epochId, navPoolPerShare, navAssetPerShare, epochAmounts.approvedShareAmounts, payoutAssetAmount, payoutPoolAmount);
    }

    /// @inheritdoc IShareClassManager
    function claimDeposit(
        PoolId poolId,
        ShareClassId scId_,
        bytes32 investor,
        AssetId depositAssetId
    ) public auth returns (uint128 payoutShareAmount, uint128 paymentAssetAmount, uint128 cancelledAssetAmount) {
        require(exists(poolId, scId_), ShareClassNotFound());
        require(endEpochId < epochId[poolId], EpochNotFound());

        UserOrder storage userOrder = depositRequest[scId_][depositAssetId][investor];

        for (uint32 epochId_ = userOrder.lastUpdate; epochId_ <= endEpochId; epochId_++) {
            EpochAmounts storage epochAmounts_ = epochAmounts[scId_][depositAssetId][epochId_];

            // Skip redeem epochs
            if (epochAmounts_.depositApproved == 0) {
                continue;
            }

            // Skip epoch if user cannot claim
            uint128 approvedAssetAmount =
                userOrder.pending.mulDiv(epochAmounts_.depositApproved, epochAmounts_.depositPending).toUint128();
            if (approvedAssetAmount == 0) {
                emit ClaimDeposit(poolId, scId_, epochId_, investor, depositAssetId, 0, userOrder.pending, 0);
                continue;
            }

            uint128 claimableShareAmount = uint256(approvedAssetAmount).mulDiv(
                epochAmounts_.depositShares, epochAmounts_.depositApproved
            ).toUint128();

            // NOTE: During approvals, we reduce pendingDeposits by the approved asset amount. However, we only reduce
            // the pending user amount if the claimable amount is non-zero.
            //
            // This extreme edge case has two implications:
            //  1. The sum of pending user orders <= pendingDeposits (instead of equality)
            //  2. The sum of claimable user amounts <= amount of minted share class tokens corresponding to the
            // approved deposit asset amount (instead of equality).
            //     I.e., it is possible for an epoch to have an excess of a share class tokens which cannot be
            // claimed by anyone. This excess is at most n-1 share tokens for an epoch with n claimable users.
            //
            // The first implication can be switched to equality if we reduce the pending user amount independent of the
            // claimable amount.
            // However, in practice, it should be extremely unlikely to have users with non-zero pending but zero
            // claimable for an epoch.
            if (claimableShareAmount > 0) {
                userOrder.pending -= approvedAssetAmount;
                payoutShareAmount += claimableShareAmount;
                paymentAssetAmount += approvedAssetAmount;
            }

            emit ClaimDeposit(
                poolId,
                scId_,
                epochId_,
                investor,
                depositAssetId,
                approvedAssetAmount,
                userOrder.pending,
                claimableShareAmount
            );
        }
        userOrder.lastUpdate = endEpochId + 1;

        cancelledAssetAmount =
            _postClaimUpdateQueued(poolId, scId_, investor, depositAssetId, userOrder, RequestType.Deposit);
    }

    /// @inheritdoc IShareClassManager
    function claimRedeem(
        PoolId poolId,
        ShareClassId scId_,
        bytes32 investor,
        AssetId payoutAssetId,
    ) public auth returns (uint128 payoutAssetAmount, uint128 paymentShareAmount, uint128 cancelledShareAmount) {
        require(exists(poolId, scId_), ShareClassNotFound());
        require(endEpochId < epochId[poolId], EpochNotFound());

        UserOrder storage userOrder = redeemRequest[scId_][payoutAssetId][investor];

        for (uint32 epochId_ = userOrder.lastUpdate; epochId_ <= endEpochId; epochId_++) {
            EpochAmounts storage epochAmounts_ = epochAmounts[scId_][payoutAssetId][epochId_];

            // Skip deposit epochs
            if (epochAmounts_.redeemApproved == 0) {
                continue;
            }

            // Skip epoch if user cannot claim
            uint128 approvedShareAmount =
                userOrder.pending.mulDiv(epochAmounts_.redeemApproved, epochAmounts_.redeemPending).toUint128();
            if (approvedShareAmount == 0) {
                emit ClaimRedeem(poolId, scId_, epochId_, investor, payoutAssetId, 0, userOrder.pending, 0);
                continue;
            }

            uint128 claimableAssetAmount = uint256(approvedShareAmount).mulDiv(
                epochAmounts_.redeemAssets, epochAmounts_.redeemApproved
            ).toUint128();

            // NOTE: During approvals, we reduce pendingRedeems by the approved share class token amount. However, we
            // only reduce the pending user amount if the claimable amount is non-zero.
            //
            // This extreme edge case has two implications:
            //  1. The sum of pending user orders <= pendingRedeems (instead of equality)
            //  2. The sum of claimable user amounts <= amount of payout asset corresponding to the approved share class
            // token amount (instead of equality).
            //     I.e., it is possible for an epoch to have an excess of a single payout asset unit which cannot be
            // claimed by anyone. This excess is at most n-1 payout asset units for an epoch with n claimable users.
            //
            // The first implication can be switched to equality if we reduce the pending user amount independent of the
            // claimable amount.
            // However, in practice, it should be extremely unlikely to have users with non-zero pending but zero
            // claimable for an epoch.
            if (claimableAssetAmount > 0) {
                paymentShareAmount += approvedShareAmount;
                payoutAssetAmount += claimableAssetAmount;
                userOrder.pending -= approvedShareAmount;
            }

            emit ClaimRedeem(
                poolId,
                scId_,
                epochId_,
                investor,
                payoutAssetId,
                approvedShareAmount,
                userOrder.pending,
                claimableAssetAmount
            );
        }

        userOrder.lastUpdate = endEpochId + 1;

        cancelledShareAmount =
            _postClaimUpdateQueued(poolId, scId_, investor, payoutAssetId, userOrder, RequestType.Redeem);
    }

    function updateMetadata(
        PoolId poolId,
        ShareClassId scId_,
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        bytes calldata
    ) external auth {
        require(exists(poolId, scId_), ShareClassNotFound());

        _updateMetadata(scId_, name, symbol, salt);

        emit UpdateMetadata(poolId, scId_, name, symbol, salt);
    }

    /// @inheritdoc IShareClassManager
    function increaseShareClassIssuance(PoolId poolId, ShareClassId scId_, uint128 amount)
        external
        auth
    {
        require(exists(poolId, scId_), ShareClassNotFound());

        uint128 newIssuance = metrics[scId_].totalIssuance + amount;
        metrics[scId_].totalIssuance = newIssuance;

        emit remoteIssueShares(poolId, scId_, amount);
    }

    /// @inheritdoc IShareClassManager
    function decreaseShareClassIssuance(PoolId poolId, ShareClassId scId_, uint128 amount)
        external
        auth
    {
        require(exists(poolId, scId_), ShareClassNotFound());
        require(metrics[scId_].totalIssuance >= amount, DecreaseMoreThanIssued());

        uint128 newIssuance = metrics[scId_].totalIssuance - amount;
        metrics[scId_].totalIssuance = newIssuance;

        emit remoteRevokeShares(poolId, scId_, amount);
    }

    /// @inheritdoc IShareClassManager
    function previewNextShareClassId(PoolId poolId) public view returns (ShareClassId scId) {
        return newShareClassId(poolId, shareClassCount[poolId] + 1);
    }

    /// @inheritdoc IShareClassManager
    function previewShareClassId(PoolId poolId, uint32 index) public pure returns (ShareClassId scId) {
        return newShareClassId(poolId, index);
    }

    /// @inheritdoc IShareClassManager
    function exists(PoolId poolId, ShareClassId scId_) public view returns (bool) {
        return shareClassIds[poolId][scId_];
    }

    function _updateMetadata(ShareClassId scId_, string calldata name, string calldata symbol, bytes32 salt) private {
        uint256 nLen = bytes(name).length;
        require(nLen > 0 && nLen <= 128, InvalidMetadataName());

        uint256 sLen = bytes(symbol).length;
        require(sLen > 0 && sLen <= 32, InvalidMetadataSymbol());
        require(!salts[salt], AlreadyUsedSalt());

        require(salt != bytes32(0), InvalidSalt());
        // Either the salt was not initialized yet or it is the same as before - i.e. updating the salt is not possible
        require(salt == metadata[scId_].salt || metadata[scId_].salt == bytes32(0));
        salts[salt] = true;

        metadata[scId_] = ShareClassMetadata(name, symbol, salt);
    }

    function _postClaimUpdateQueued(
        PoolId poolId,
        ShareClassId scId_,
        bytes32 investor,
        AssetId assetId,
        UserOrder storage userOrder,
        RequestType requestType
    ) private returns (uint128 cancelledAmount) {
        QueuedOrder storage queued = requestType == RequestType.Deposit
            ? queuedDepositRequest[scId_][assetId][investor]
            : queuedRedeemRequest[scId_][assetId][investor];

        // Increment pending by queued or cancel everything
        uint128 updatePendingAmount = queued.isCancelling ? userOrder.pending : queued.amount;
        if (queued.isCancelling) {
            cancelledAmount = userOrder.pending + queued.amount;
            userOrder.pending = 0;
        } else {
            userOrder.pending += queued.amount;
        }

        if (requestType == RequestType.Deposit) {
            _updatePendingDeposit(
                poolId,
                scId_,
                updatePendingAmount,
                !queued.isCancelling,
                investor,
                assetId,
                userOrder,
                QueuedOrder(false, 0)
            );
        } else {
            _updatePendingRedeem(
                poolId,
                scId_,
                updatePendingAmount,
                !queued.isCancelling,
                investor,
                assetId,
                userOrder,
                QueuedOrder(false, 0)
            );
        }

        // Clear queued
        queued.isCancelling = false;
        queued.amount = 0;
    }

    /// @notice Updates the amount of a deposit or redeem request.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId_ Identifier of the share class
    /// @param amount Amount which is updated
    /// @param isIncrement Whether the amount is positive (additional request) or negative (cancellation)
    /// @param investor Address of the entity which is depositing
    /// @param assetId Identifier of the asset which the investor either used as deposit or wants to redeem to
    /// @param requestType Flag indicating whether the request is a deposit or redeem request
    /// @return cancelledAmount Pending amount which was cancelled
    function _updatePending(
        PoolId poolId,
        ShareClassId scId_,
        uint128 amount,
        bool isIncrement,
        bytes32 investor,
        AssetId assetId,
        RequestType requestType
    ) private returns (uint128 cancelledAmount) {
        UserOrder storage userOrder = requestType == RequestType.Deposit
            ? depositRequest[scId_][assetId][investor]
            : redeemRequest[scId_][assetId][investor];
        QueuedOrder storage queued = requestType == RequestType.Deposit
            ? queuedDepositRequest[scId_][assetId][investor]
            : queuedRedeemRequest[scId_][assetId][investor];

        // We must only update either queued or pending
        if (_updateQueued(poolId, scId_, amount, isIncrement, investor, assetId, userOrder, queued, requestType)) {
            return 0;
        }

        cancelledAmount = isIncrement ? 0 : amount;
        userOrder.pending = isIncrement ? userOrder.pending + amount : userOrder.pending - amount;
        userOrder.lastUpdate = epochId[poolId];

        if (requestType == RequestType.Deposit) {
            _updatePendingDeposit(poolId, scId_, amount, isIncrement, investor, assetId, userOrder, queued);
        } else {
            _updatePendingRedeem(poolId, scId_, amount, isIncrement, investor, assetId, userOrder, queued);
        }
    }

    /// @notice Checks whether the pending amount can be updated. If not, it updates the queued amount.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId_ Identifier of the share class
    /// @param amount Amount which is updated
    /// @param isIncrement Whether the amount is positive (additional request) or negative (cancellation)
    /// @param investor Address of the entity which is depositing
    /// @param assetId Identifier of the asset which the investor either used as deposit or wants to redeem to
    /// @param userOrder User order storage for the deposit or redeem request
    /// @param requestType Flag indicating whether the request is a deposit or redeem request
    /// @return skipPendingUpdate Flag indicating whether the pending amount can be updated which is true if the user
    /// does not need to claim
    function _updateQueued(
        PoolId poolId,
        ShareClassId scId_,
        uint128 amount,
        bool isIncrement,
        bytes32 investor,
        AssetId assetId,
        UserOrder storage userOrder,
        QueuedOrder storage queued,
        RequestType requestType
    ) private returns (bool skipPendingUpdate) {
        uint128 latestApproval = requestType == RequestType.Deposit
            ? epochPointers[scId_][assetId].latestDepositApproval
            : epochPointers[scId_][assetId].latestRedeemApproval;

        // Short circuit if user can mutate pending, i.e. last update happened after latest approval or is first update
        if (userOrder.lastUpdate > latestApproval || userOrder.pending == 0 || latestApproval == 0) {
            return false;
        }

        // Block increasing queued amount if cancelling is already queued
        // NOTE: Can only happen due to race condition as CV blocks requests if cancellation is in progress
        require(!(queued.isCancelling == true && amount > 0), CancellationQueued());

        if (!isIncrement) {
            queued.isCancelling = true;
        } else {
            queued.amount += amount;
        }

        uint128 pendingTotal =
            requestType == RequestType.Deposit ? pendingDeposit[scId_][assetId] : pendingRedeem[scId_][assetId];

        emit UpdateRequest(
            poolId,
            scId_,
            epochId[poolId],
            requestType,
            investor,
            assetId,
            userOrder.pending,
            pendingTotal,
            queued.amount,
            queued.isCancelling
        );

        return true;
    }

    function _updatePendingDeposit(
        PoolId poolId,
        ShareClassId scId_,
        uint128 amount,
        bool isIncrement,
        bytes32 investor,
        AssetId assetId,
        UserOrder storage userOrder,
        QueuedOrder memory queued
    ) private {
        uint128 pendingTotal = pendingDeposit[scId_][assetId];
        pendingDeposit[scId_][assetId] = isIncrement ? pendingTotal + amount : pendingTotal - amount;
        pendingTotal = pendingDeposit[scId_][assetId];

        emit UpdateRequest(
            poolId,
            scId_,
            epochId[poolId],
            RequestType.Deposit,
            investor,
            assetId,
            userOrder.pending,
            pendingTotal,
            queued.amount,
            queued.isCancelling
        );
    }

    function _updatePendingRedeem(
        PoolId poolId,
        ShareClassId scId_,
        uint128 amount,
        bool isIncrement,
        bytes32 investor,
        AssetId assetId,
        UserOrder storage userOrder,
        QueuedOrder memory queued
    ) private {
        uint128 pendingTotal = pendingRedeem[scId_][assetId];
        pendingRedeem[scId_][assetId] = isIncrement ? pendingTotal + amount : pendingTotal - amount;
        pendingTotal = pendingRedeem[scId_][assetId];

        emit UpdateRequest(
            poolId,
            scId_,
            epochId[poolId],
            RequestType.Redeem,
            investor,
            assetId,
            userOrder.pending,
            pendingTotal,
            queued.amount,
            queued.isCancelling
        );
    }
}
