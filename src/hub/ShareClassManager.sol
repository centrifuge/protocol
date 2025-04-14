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
    mapping(ShareClassId scId => mapping(AssetId assetId => uint32)) public depositEpochId;
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
    mapping(ShareClassId scId => mapping(AssetId depositAssetId => uint128 pending)) public pendingDeposit;

    mapping(ShareClassId scId => mapping(AssetId payoutAssetId => mapping(bytes32 investor => UserOrder pending)))
        public redeemRequest;
    mapping(ShareClassId scId => mapping(AssetId depositAssetId => mapping(bytes32 investor => UserOrder pending)))
        public depositRequest;
    mapping(ShareClassId scId => mapping(AssetId payoutAssetId => mapping(bytes32 investor => QueuedOrder queued)))
        public queuedRedeemRequest;
    mapping(ShareClassId scId => mapping(AssetId depositAssetId => mapping(bytes32 investor => QueuedOrder queued)))
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
        uint32 epochId = depositEpochId[scId_][depositAssetId] + 1;

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
        pendingAssetAmount -= approvedAssetAmount;
        depositEpochId[scId_][depositAssetId] = epochId;
        emit ApproveDeposits(
            poolId, scId_, depositAssetId, epochId, approvedPoolAmount, approvedAssetAmount, pendingAssetAmount
        );
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
        redeemEpochId[scId_][payoutAssetId] = epochId;
        emit ApproveRedeems(poolId, scId_, payoutAssetId, epochId, approvedShareAmount, pendingShareAmount);
    }

    /// @inheritdoc IShareClassManager
    function issueShares(PoolId poolId, ShareClassId scId_, AssetId depositAssetId, D18 navPoolPerShare)
        public
        auth
        returns (uint128 issuedShareAmount, uint128 depositAssetAmount, uint128 paymentPoolAmount)
    {
        require(exists(poolId, scId_), ShareClassNotFound());
        uint32 epochId = issueEpochId[scId_][depositAssetId] + 1;
        require(epochId <= depositEpochId[scId_][depositAssetId], EpochNotFound());

        EpochInvestAmounts storage epochAmounts = epochInvestAmounts[scId_][depositAssetId][epochId];
        epochAmounts.navPoolPerShare = navPoolPerShare;

        issuedShareAmount = ConversionLib.convertWithPrice(
            epochAmounts.approvedAssetAmount,
            hubRegistry.decimals(depositAssetId),
            hubRegistry.decimals(poolId),
            _navSharePerAsset(epochAmounts)
        ).toUint128();

        metrics[scId_].totalIssuance += issuedShareAmount;
        epochAmounts.issuedAt = block.timestamp.toUint64();
        issueEpochId[scId_][depositAssetId] = epochId;

        depositAssetAmount = epochAmounts.approvedAssetAmount;
        paymentPoolAmount = epochAmounts.approvedPoolAmount;

        emit IssueShares(
            poolId, scId_, depositAssetId, epochId, navPoolPerShare, _navAssetPerShare(epochAmounts), issuedShareAmount
        );
    }

    /// @inheritdoc IShareClassManager
    function revokeShares(PoolId poolId, ShareClassId scId_, AssetId payoutAssetId, D18 navPoolPerShare)
        public
        auth
        returns (uint128 revokedShareAmount, uint128 payoutAssetAmount, uint128 payoutPoolAmount)
    {
        require(exists(poolId, scId_), ShareClassNotFound());
        uint32 epochId = revokeEpochId[scId_][payoutAssetId] + 1;
        require(epochId <= redeemEpochId[scId_][payoutAssetId], EpochNotFound());

        EpochRedeemAmounts storage epochAmounts = epochRedeemAmounts[scId_][payoutAssetId][epochId];
        epochAmounts.navPoolPerShare = navPoolPerShare;

        require(epochAmounts.approvedShareAmount <= metrics[scId_].totalIssuance, RevokeMoreThanIssued());

        payoutAssetAmount = ConversionLib.convertWithPrice(
            epochAmounts.approvedShareAmount,
            hubRegistry.decimals(poolId),
            hubRegistry.decimals(payoutAssetId),
            _navAssetPerShare(epochAmounts)
        ).toUint128();
        // NOTE: shares and pool currency have the same decimals - no conversion needed!
        payoutPoolAmount = navPoolPerShare.mulUint128(epochAmounts.approvedShareAmount);
        revokedShareAmount = epochAmounts.approvedShareAmount;

        metrics[scId_].totalIssuance -= epochAmounts.approvedShareAmount;
        epochAmounts.payoutAssetAmount = payoutAssetAmount;
        epochAmounts.revokedAt = block.timestamp.toUint64();
        revokeEpochId[scId_][payoutAssetId] = epochId;

        emit RevokeShares(
            poolId,
            scId_,
            payoutAssetId,
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
            uint128 depositAssetAmount,
            uint128 cancelledAssetAmount,
            bool canClaimAgain
        )
    {
        require(exists(poolId, scId_), ShareClassNotFound());

        UserOrder storage userOrder = depositRequest[scId_][depositAssetId][investor];
        require(userOrder.pending > 0, NoOrderFound());
        require(userOrder.lastUpdate <= issueEpochId[scId_][depositAssetId], IssuanceRequired());
        canClaimAgain = userOrder.lastUpdate == issueEpochId[scId_][depositAssetId];

        EpochInvestAmounts storage epochAmounts = epochInvestAmounts[scId_][depositAssetId][userOrder.lastUpdate];

        if (epochAmounts.approvedAssetAmount == 0) {
            emit ClaimDeposit(
                poolId,
                scId_,
                userOrder.lastUpdate,
                investor,
                depositAssetId,
                depositAssetAmount,
                userOrder.pending,
                payoutShareAmount,
                epochAmounts.issuedAt
            );
            userOrder.lastUpdate += 1;
            return (payoutShareAmount, depositAssetAmount, cancelledAssetAmount, canClaimAgain);
        }

        // Skip epoch if user cannot claim
        depositAssetAmount = _fulfillRatio(epochAmounts).mulUint128(userOrder.pending);

        if (depositAssetAmount == 0) {
            emit ClaimDeposit(
                poolId,
                scId_,
                userOrder.lastUpdate,
                investor,
                depositAssetId,
                depositAssetAmount,
                userOrder.pending,
                payoutShareAmount,
                epochAmounts.issuedAt
            );
            userOrder.lastUpdate += 1;
            return (payoutShareAmount, depositAssetAmount, cancelledAssetAmount, canClaimAgain);
        }

        payoutShareAmount = ConversionLib.convertWithPrice(
            depositAssetAmount,
            hubRegistry.decimals(depositAssetId),
            hubRegistry.decimals(poolId),
            _navSharePerAsset(epochAmounts)
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
        if (payoutShareAmount > 0) {
            userOrder.pending -= depositAssetAmount;
        }

        emit ClaimDeposit(
            poolId,
            scId_,
            userOrder.lastUpdate,
            investor,
            depositAssetId,
            depositAssetAmount,
            userOrder.pending,
            payoutShareAmount,
            epochAmounts.issuedAt
        );

        userOrder.lastUpdate += 1;
        // If there is nothing to claim anymore we can short circuit the in between epochs
        if (userOrder.pending == 0) {
            // The current epoch is always one step ahead of the stored one
            userOrder.lastUpdate = nowDepositEpoch(scId_, depositAssetId);
            canClaimAgain = false;
        }

        if (depositEpochId[scId_][depositAssetId] == userOrder.lastUpdate) {
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
            uint128 depositShareAmount,
            uint128 cancelledShareAmount,
            bool canClaimAgain
        )
    {
        require(exists(poolId, scId_), ShareClassNotFound());

        UserOrder storage userOrder = redeemRequest[scId_][payoutAssetId][investor];
        require(userOrder.pending > 0, NoOrderFound());
        require(userOrder.lastUpdate <= revokeEpochId[scId_][payoutAssetId], RevocationRequired());
        canClaimAgain = userOrder.lastUpdate == revokeEpochId[scId_][payoutAssetId];

        EpochRedeemAmounts storage epochAmounts = epochRedeemAmounts[scId_][payoutAssetId][userOrder.lastUpdate];

        {
            if (epochAmounts.approvedShareAmount == 0) {
                emit ClaimRedeem(
                    poolId,
                    scId_,
                    userOrder.lastUpdate,
                    investor,
                    payoutAssetId,
                    payoutAssetAmount,
                    userOrder.pending,
                    depositShareAmount,
                    epochAmounts.revokedAt
                );
                userOrder.lastUpdate += 1;
                return (payoutAssetAmount, depositShareAmount, cancelledShareAmount, canClaimAgain);
            }
        }

        depositShareAmount = _fulfillRatio(epochAmounts).mulUint128(userOrder.pending);
        if (depositShareAmount == 0) {
            emit ClaimDeposit(
                poolId,
                scId_,
                userOrder.lastUpdate,
                investor,
                payoutAssetId,
                payoutAssetAmount,
                userOrder.pending,
                depositShareAmount,
                epochAmounts.revokedAt
            );
            userOrder.lastUpdate += 1;
            return (payoutAssetAmount, depositShareAmount, cancelledShareAmount, canClaimAgain);
        }

        payoutAssetAmount = ConversionLib.convertWithPrice(
            depositShareAmount,
            hubRegistry.decimals(poolId),
            hubRegistry.decimals(payoutAssetId),
            _navAssetPerShare(epochAmounts)
        ).toUint128();

        {
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
                userOrder.pending -= depositShareAmount;
            }
        }

        emit ClaimRedeem(
            poolId,
            scId_,
            userOrder.lastUpdate,
            investor,
            payoutAssetId,
            payoutAssetAmount,
            userOrder.pending,
            depositShareAmount,
            epochAmounts.revokedAt
        );

        userOrder.lastUpdate += 1;

        // If there is nothing to claim anymore we can short circuit the in between epochs
        if (userOrder.pending == 0) {
            // The current epoch is always one step ahead of the stored one
            userOrder.lastUpdate = nowRedeemEpoch(scId_, payoutAssetId);
            canClaimAgain = false;
        }

        if (redeemEpochId[scId_][payoutAssetId] == userOrder.lastUpdate) {
            cancelledShareAmount =
                _postClaimUpdateQueued(poolId, scId_, investor, payoutAssetId, userOrder, RequestType.Redeem);
        }
    }

    function updatePricePerShare(PoolId poolId, ShareClassId scId_, D18 navPoolPerShare) external auth {
        require(exists(poolId, scId_), ShareClassNotFound());

        ShareClassMetrics storage m = metrics[scId_];
        m.navPerShare = navPoolPerShare;
        emit UpdateShareClass(
            poolId, scId_, navPoolPerShare.mulUint128(m.totalIssuance), navPoolPerShare, m.totalIssuance
        );
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

    /// @inheritdoc IShareClassManager
    function nowDepositEpoch(ShareClassId scId_, AssetId depositAssetId) public view returns (uint32) {
        return depositEpochId[scId_][depositAssetId] + 1;
    }

    /// @inheritdoc IShareClassManager
    function nowRedeemEpoch(ShareClassId scId_, AssetId depositAssetId) public view returns (uint32) {
        return redeemEpochId[scId_][depositAssetId] + 1;
    }

    /// @inheritdoc IShareClassManager
    function maxDepositClaims(ShareClassId scId_, bytes32 investor, AssetId depositAssetId)
        public
        view
        returns (uint32)
    {
        UserOrder storage userOrder = depositRequest[scId_][depositAssetId][investor];
        uint32 lastIssueEpoch = issueEpochId[scId_][depositAssetId];

        // Catching
        //  - no order set
        //  - order present but not yet
        if (userOrder.pending == 0 || userOrder.lastUpdate > lastIssueEpoch) {
            return 0;
        }

        // Diff is always last ...
        return userOrder.lastUpdate - issueEpochId[scId_][depositAssetId] + 1;
    }

    /// @inheritdoc IShareClassManager
    function maxRedeemClaims(ShareClassId scId_, bytes32 investor, AssetId payoutAssetId)
        public
        view
        returns (uint32)
    {
        UserOrder storage userOrder = redeemRequest[scId_][payoutAssetId][investor];
        uint32 lastRevokeEpoch = revokeEpochId[scId_][payoutAssetId];

        // Catching
        //  - no order set
        //  - order present but not yet
        if (userOrder.pending == 0 || userOrder.lastUpdate > lastRevokeEpoch) {
            return 0;
        }

        // Diff is always last ...
        return userOrder.lastUpdate - revokeEpochId[scId_][payoutAssetId] + 1;
    }

    function _updateMetadata(ShareClassId scId_, string calldata name, string calldata symbol, bytes32 salt) private {
        uint256 nameLen = bytes(name).length;
        require(nameLen > 0 && nameLen <= 128, InvalidMetadataName());

        uint256 symbolLen = bytes(symbol).length;
        require(symbolLen > 0 && symbolLen <= 32, InvalidMetadataSymbol());

        require(salt != bytes32(0), InvalidSalt());

        ShareClassMetadata storage meta = metadata[scId_];

        // Ensure that the salt remains unchanged if it's already set,
        // or that it is being set for the first time.
        require(salt == meta.salt || meta.salt == bytes32(0), InvalidSalt());

        // If this is the first time setting the metadata, ensure the salt wasn't already used.
        if (meta.salt == bytes32(0)) {
            require(!salts[salt], AlreadyUsedSalt());
            salts[salt] = true;
        }

        meta.name = name;
        meta.symbol = symbol;
        meta.salt = salt;
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
        userOrder.pending = isIncrement ? userOrder.pending + amount : 0;

        userOrder.lastUpdate =
            requestType == RequestType.Deposit ? nowDepositEpoch(scId_, assetId) : nowRedeemEpoch(scId_, assetId);

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
        uint32 lastEpoch =
            requestType == RequestType.Deposit ? issueEpochId[scId_][assetId] : redeemEpochId[scId_][assetId];
        uint32 currentEpoch = lastEpoch + 1;

        // Short circuit if user can mutate pending, i.e. last update happened after latest approval or is first update
        if (userOrder.lastUpdate == currentEpoch || userOrder.pending == 0 || lastEpoch == 0) {
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

        if (requestType == RequestType.Deposit) {
            uint128 pendingTotal = pendingDeposit[scId_][assetId];
            emit UpdateDepositRequest(
                poolId,
                scId_,
                assetId,
                currentEpoch,
                investor,
                userOrder.pending,
                pendingTotal,
                queued.amount,
                queued.isCancelling
            );
        } else {
            uint128 pendingTotal = pendingRedeem[scId_][assetId];

            emit UpdateRedeemRequest(
                poolId,
                scId_,
                assetId,
                currentEpoch,
                investor,
                userOrder.pending,
                pendingTotal,
                queued.amount,
                queued.isCancelling
            );
        }

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

        emit UpdateDepositRequest(
            poolId,
            scId_,
            assetId,
            issueEpochId[scId_][assetId] + 1,
            investor,
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

        emit UpdateRedeemRequest(
            poolId,
            scId_,
            assetId,
            redeemEpochId[scId_][assetId] + 1,
            investor,
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

    function _navSharePerAsset(EpochRedeemAmounts memory amounts) private pure returns (D18) {
        return amounts.pricePoolPerAsset / amounts.navPoolPerShare;
    }

    function _navSharePerAsset(EpochInvestAmounts memory amounts) private pure returns (D18) {
        return amounts.pricePoolPerAsset / amounts.navPoolPerShare;
    }

    function _fulfillRatio(EpochRedeemAmounts memory amounts) private pure returns (D18) {
        return d18(amounts.approvedShareAmount, amounts.pendingShareAmount);
    }

    function _fulfillRatio(EpochInvestAmounts memory amounts) private pure returns (D18) {
        return d18(amounts.approvedAssetAmount, amounts.pendingAssetAmount);
    }
}
