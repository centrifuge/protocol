// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {ConversionLib} from "src/misc/libraries/ConversionLib.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId, newShareClassId} from "src/common/types/ShareClassId.sol";

import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {
    IShareClassManager,
    EpochInvestAmounts,
    EpochRedeemAmounts,
    UserOrder,
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
    // TODO: Make public in IShareClassManager interface?
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
        AssetId depositAssetId,
        D18 pricePoolPerAsset
    ) external auth returns (uint128 pendingAssetAmount, uint128 approvedPoolAmount) {
        require(exists(poolId, scId_), ShareClassNotFound());
        uint32 epochId = investEpochId[scId_][depositAssetId] + 1;

        // Limit in case approved > pending due to race condition of FM approval and async incoming requests
        pendingAssetAmount = pendingDeposit[scId_][depositAssetId];
        require(approvedAssetAmount <= pendingAssetAmount, NotEnoughPending());
        require(approvedAssetAmount > 0, ZeroApprovalAmount());

        // Update epoch data
        EpochInvestAmounts storage epochAmounts = epochInvestAmounts[scId_][depositAssetId][epochId];
        epochAmounts.approvedAssetAmount = approvedAssetAmount;
        epochAmounts.approvedPoolAmount = ConversionLib.convertWithPrice(
            approvedAssetAmount, hubRegistry.decimals(depositAssetId), hubRegistry.decimals(poolId), pricePoolPerAsset
        ).toUint128();
        epochAmounts.pendingAssetAmount = pendingAssetAmount;
        epochAmounts.pricePoolPerAsset = pricePoolPerAsset;

        // Reduce pending
        pendingDeposit[scId_][depositAssetId] -= approvedAssetAmount;
        investEpochId[scId_][depositAssetId] = epochId;
        pendingAssetAmount -= approvedAssetAmount;

        emit ApproveDeposits(
            poolId, scId_, epochId, depositAssetId, approvedPoolAmount, approvedAssetAmount, pendingAssetAmount
        );

        investEpochId[scId_][depositAssetId] = epochId;
        emit NewInvestEpoch(poolId, depositAssetId, epochId);
    }

    /// @inheritdoc IShareClassManager
    function approveRedeems(
        PoolId poolId,
        ShareClassId scId_,
        uint128 approvedShareAmount,
        AssetId payoutAssetId,
        D18 pricePoolPerAsset
    ) external auth returns (uint128 pendingShareAmount) {
        require(exists(poolId, scId_), ShareClassNotFound());
        uint32 epochId = redeemEpochId[scId_][payoutAssetId] + 1;
        // Limit in case approved > pending due to race condition of FM approval and async incoming requests
        pendingShareAmount = pendingRedeem[scId_][payoutAssetId];
        require(approvedShareAmount <= pendingShareAmount, NotEnoughPending());
        require(approvedShareAmount > 0, ZeroApprovalAmount());

        // Update epoch data
        EpochRedeemAmounts storage epochAmounts = epochRedeemAmounts[scId_][payoutAssetId][epochId];
        epochAmounts.approvedShareAmount = approvedShareAmount;
        epochAmounts.pendingShareAmount = pendingShareAmount;
        epochAmounts.pricePoolPerAsset = pricePoolPerAsset;

        // Reduce pending
        pendingRedeem[scId_][payoutAssetId] -= approvedShareAmount;
        pendingShareAmount -= approvedShareAmount;
        emit ApproveRedeems(poolId, scId_, epochId, payoutAssetId, approvedShareAmount, pendingShareAmount);

        redeemEpochId[scId_][payoutAssetId] = epochId;
        emit NewRedeemEpoch(poolId, payoutAssetId, epochId);
    }

    /// @inheritdoc IShareClassManager
    function issueShares(PoolId poolId, ShareClassId scId_, AssetId depositAssetId, D18 navPoolPerShare)
        public
        auth
        returns (uint128 issuedShareAmount, uint128 paymentAssetAmount, uint128 paymentPoolAmount)
    {
        require(exists(poolId, scId_), ShareClassNotFound());
        uint32 epochId = issueEpochId[scId_][depositAssetId] + 1;
        require(epochId <= investEpochId[scId_][depositAssetId], EpochNotFound());

        EpochInvestAmounts storage epochAmounts = epochInvestAmounts[scId_][depositAssetId][epochId];
        epochAmounts.navPoolPerShare = navPoolPerShare;

        issuedShareAmount = ConversionLib.convertWithPrice(
            epochAmounts.approvedAssetAmount,
            hubRegistry.decimals(depositAssetId),
            hubRegistry.decimals(poolId),
            _navAssetPerShare(epochAmounts)
        ).toUint128();
        metrics[scId_].totalIssuance += issuedShareAmount;
        epochAmounts.issuedAt = block.timestamp.toUint64();
        issueEpochId[scId_][depositAssetId] = epochId;

        paymentAssetAmount = epochAmounts.approvedAssetAmount;
        paymentPoolAmount = epochAmounts.approvedPoolAmount;

        emit IssueShares(poolId, scId_, epochId, navPoolPerShare, _navAssetPerShare(epochAmounts), issuedShareAmount);
    }

    /// @inheritdoc IShareClassManager
    function revokeShares(PoolId poolId, ShareClassId scId_, AssetId paymentAssetId, D18 navPoolPerShare)
        public
        auth
        returns (uint128 revokedShareAmount, uint128 payoutAssetAmount, uint128 payoutPoolAmount)
    {
        require(exists(poolId, scId_), ShareClassNotFound());
        uint32 epochId = revokeEpochId[scId_][paymentAssetId] + 1;
        require(epochId <= redeemEpochId[scId_][paymentAssetId], EpochNotFound());

        EpochRedeemAmounts storage epochAmounts = epochRedeemAmounts[scId_][paymentAssetId][epochId];
        epochAmounts.navPoolPerShare = navPoolPerShare;

        require(epochAmounts.approvedShareAmount <= metrics[scId_].totalIssuance, RevokeMoreThanIssued());

        payoutAssetAmount = ConversionLib.convertWithPrice(
            epochAmounts.approvedShareAmount,
            hubRegistry.decimals(poolId),
            hubRegistry.decimals(paymentAssetId),
            _navAssetPerShare(epochAmounts)
        ).toUint128();
        // NOTE: shares and pool currency have the same decimals - no conversion needed!
        payoutPoolAmount = navPoolPerShare.mulUint128(epochAmounts.approvedShareAmount);
        revokedShareAmount = epochAmounts.approvedShareAmount;

        metrics[scId_].totalIssuance -= epochAmounts.approvedShareAmount;
        epochAmounts.payoutAssetAmount = payoutAssetAmount;
        epochAmounts.revokedAt = block.timestamp.toUint64();
        revokeEpochId[scId_][paymentAssetId] = epochId;

        emit RevokeShares(
            poolId,
            scId_,
            epochId,
            navPoolPerShare,
            _navAssetPerShare(epochAmounts),
            epochAmounts.approvedShareAmount,
            payoutAssetAmount,
            payoutPoolAmount
        );
    }

    /// @inheritdoc IShareClassManager
    function claimDeposit(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId depositAssetId)
        public
        auth
        returns (
            uint128 payoutShareAmount,
            uint128 paymentAssetAmount,
            uint128 cancelledAssetAmount,
            bool canClaimAgain
        )
    {
        require(exists(poolId, scId_), ShareClassNotFound());

        UserOrder storage userOrder = depositRequest[scId_][depositAssetId][investor];
        require(userOrder.lastUpdate <= issueEpochId[scId_][depositAssetId], IssuanceRequired());
        uint32 epochId = userOrder.lastUpdate;
        userOrder.lastUpdate += 1;
        canClaimAgain = userOrder.lastUpdate == issueEpochId[scId_][depositAssetId];

        EpochInvestAmounts storage epochAmounts = epochInvestAmounts[scId_][depositAssetId][epochId];

        if (epochAmounts.approvedAssetAmount == 0) {
            emit ClaimDeposit(
                poolId,
                scId_,
                epochId,
                investor,
                depositAssetId,
                paymentAssetAmount,
                userOrder.pending,
                payoutShareAmount,
                epochAmounts.issuedAt
            );
            return (payoutShareAmount, paymentAssetAmount, cancelledAssetAmount, canClaimAgain);
        }

        // Skip epoch if user cannot claim
        paymentAssetAmount =
            userOrder.pending.mulDiv(epochAmounts.approvedAssetAmount, epochAmounts.pendingAssetAmount).toUint128();

        if (paymentAssetAmount == 0) {
            emit ClaimDeposit(
                poolId,
                scId_,
                epochId,
                investor,
                depositAssetId,
                paymentAssetAmount,
                userOrder.pending,
                payoutShareAmount,
                epochAmounts.issuedAt
            );
            return (payoutShareAmount, paymentAssetAmount, cancelledAssetAmount, canClaimAgain);
        }

        payoutShareAmount = _navAssetPerShare(epochAmounts).reciprocalMulUint128(paymentAssetAmount);

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
        if (payoutShareAmount > 0) {
            userOrder.pending -= paymentAssetAmount;
        }

        emit ClaimDeposit(
            poolId,
            scId_,
            epochId,
            investor,
            depositAssetId,
            paymentAssetAmount,
            userOrder.pending,
            payoutShareAmount,
            epochAmounts.issuedAt
        );

        if (investEpochId[scId_][depositAssetId] == userOrder.lastUpdate) {
            cancelledAssetAmount =
                _postClaimUpdateQueued(poolId, scId_, investor, depositAssetId, userOrder, RequestType.Deposit);
        }
    }

    /// @inheritdoc IShareClassManager
    function claimRedeem(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId payoutAssetId)
        public
        auth
        returns (
            uint128 payoutAssetAmount,
            uint128 paymentShareAmount,
            uint128 cancelledShareAmount,
            bool canClaimAgain
        )
    {
        require(exists(poolId, scId_), ShareClassNotFound());

        UserOrder storage userOrder = redeemRequest[scId_][payoutAssetId][investor];
        require(userOrder.lastUpdate <= revokeEpochId[scId_][payoutAssetId], RevocationRequired());
        uint32 epochId = userOrder.lastUpdate;
        userOrder.lastUpdate += 1;
        canClaimAgain = userOrder.lastUpdate == revokeEpochId[scId_][payoutAssetId];

        EpochRedeemAmounts storage epochAmounts = epochRedeemAmounts[scId_][payoutAssetId][epochId];

        if (epochAmounts.approvedShareAmount == 0) {
            emit ClaimRedeem(
                poolId,
                scId_,
                epochId,
                investor,
                payoutAssetId,
                payoutAssetAmount,
                userOrder.pending,
                paymentShareAmount,
                epochAmounts.revokedAt
            );
            return (payoutAssetAmount, paymentShareAmount, cancelledShareAmount, canClaimAgain);
        }

        paymentShareAmount =
            userOrder.pending.mulDiv(epochAmounts.approvedShareAmount, epochAmounts.pendingShareAmount).toUint128();
        if (paymentShareAmount == 0) {
            emit ClaimDeposit(
                poolId,
                scId_,
                epochId,
                investor,
                payoutAssetId,
                payoutAssetAmount,
                userOrder.pending,
                paymentShareAmount,
                epochAmounts.revokedAt
            );
            return (payoutAssetAmount, paymentShareAmount, cancelledShareAmount, canClaimAgain);
        }

        payoutAssetAmount = ConversionLib.convertWithPrice(
            paymentShareAmount,
            hubRegistry.decimals(poolId),
            hubRegistry.decimals(payoutAssetId),
            _navAssetPerShare(epochAmounts)
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
        if (payoutAssetAmount > 0) {
            userOrder.pending -= paymentShareAmount;
        }

        emit ClaimRedeem(
            poolId,
            scId_,
            epochId,
            investor,
            payoutAssetId,
            payoutAssetAmount,
            userOrder.pending,
            paymentShareAmount,
            epochAmounts.revokedAt
        );

        if (redeemEpochId[scId_][payoutAssetId] == userOrder.lastUpdate) {
            cancelledShareAmount =
                _postClaimUpdateQueued(poolId, scId_, investor, payoutAssetId, userOrder, RequestType.Redeem);
        }
    }

    function updateShareClassPrice(PoolId poolId, ShareClassId scId_, D18 navPoolPerShare) external auth {
        require(exists(poolId, scId_), ShareClassNotFound());

        ShareClassMetrics storage m = metrics[scId_];
        m.navPerShare = navPoolPerShare;
        emit UpdateShareClass(poolId, scId_, navPoolPerShare.mulUint128(m.totalIssuance), navPoolPerShare, m.totalIssuance);
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
    function increaseShareClassIssuance(PoolId poolId, ShareClassId scId_, uint128 amount) external auth {
        require(exists(poolId, scId_), ShareClassNotFound());

        uint128 newIssuance = metrics[scId_].totalIssuance + amount;
        metrics[scId_].totalIssuance = newIssuance;

        emit RemoteIssueShares(poolId, scId_, amount);
    }

    /// @inheritdoc IShareClassManager
    function decreaseShareClassIssuance(PoolId poolId, ShareClassId scId_, uint128 amount) external auth {
        require(exists(poolId, scId_), ShareClassNotFound());
        require(metrics[scId_].totalIssuance >= amount, DecreaseMoreThanIssued());

        uint128 newIssuance = metrics[scId_].totalIssuance - amount;
        metrics[scId_].totalIssuance = newIssuance;

        emit RemoteRevokeShares(poolId, scId_, amount);
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

        uint32 currentEpoch =
            requestType == RequestType.Deposit ? investEpochId[scId_][assetId] : redeemEpochId[scId_][assetId];
        userOrder.lastUpdate = currentEpoch;

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
        uint32 currentEpoch =
            requestType == RequestType.Deposit ? issueEpochId[scId_][assetId] : redeemEpochId[scId_][assetId];

        // Short circuit if user can mutate pending, i.e. last update happened after latest approval or is first update
        if (userOrder.lastUpdate == currentEpoch || userOrder.pending == 0 || currentEpoch == 0) {
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
            currentEpoch,
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
            issueEpochId[scId_][assetId],
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
            redeemEpochId[scId_][assetId],
            RequestType.Redeem,
            investor,
            assetId,
            userOrder.pending,
            pendingTotal,
            queued.amount,
            queued.isCancelling
        );
    }

    function _navAssetPerShare(EpochRedeemAmounts memory amounts) private pure returns (D18) {
        return amounts.navPoolPerShare / amounts.pricePoolPerAsset;
    }

    function _navAssetPerShare(EpochInvestAmounts memory amounts) private pure returns (D18) {
        return amounts.navPoolPerShare / amounts.pricePoolPerAsset;
    }
}
