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
    /// @inheritdoc IShareClassManager
    mapping(ShareClassId scId => ShareClassMetrics) public metrics;
    /// @inheritdoc IShareClassManager
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

    /// @inheritdoc IShareClassManager
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
        AssetId depositAssetId,
        uint32 nowDepositEpochId,
        uint128 approvedAssetAmount,
        D18 pricePoolPerAsset
    ) external auth returns (uint128 pendingAssetAmount, uint128 approvedPoolAmount) {
        require(exists(poolId, scId_), ShareClassNotFound());
        require(
            nowDepositEpochId == nowDepositEpoch(scId_, depositAssetId),
            EpochNotInSequence(nowDepositEpochId, nowDepositEpoch(scId_, depositAssetId))
        );

        // Limit in case approved > pending due to race condition of FM approval and async incoming requests
        pendingAssetAmount = pendingDeposit[scId_][depositAssetId];
        require(approvedAssetAmount <= pendingAssetAmount, InsufficientPending());
        require(approvedAssetAmount > 0, ZeroApprovalAmount());

        approvedPoolAmount = ConversionLib.convertWithPrice(
            approvedAssetAmount, hubRegistry.decimals(depositAssetId), hubRegistry.decimals(poolId), pricePoolPerAsset
        ).toUint128();

        // Update epoch data
        EpochInvestAmounts storage epochAmounts = epochInvestAmounts[scId_][depositAssetId][nowDepositEpochId];
        epochAmounts.approvedAssetAmount = approvedAssetAmount;
        epochAmounts.approvedPoolAmount = approvedPoolAmount;
        epochAmounts.pendingAssetAmount = pendingAssetAmount;
        epochAmounts.pricePoolPerAsset = pricePoolPerAsset;

        // Reduce pending
        pendingDeposit[scId_][depositAssetId] -= approvedAssetAmount;
        pendingAssetAmount -= approvedAssetAmount;

        depositEpochId[scId_][depositAssetId] = nowDepositEpochId;
        emit ApproveDeposits(
            poolId,
            scId_,
            depositAssetId,
            nowDepositEpochId,
            approvedPoolAmount,
            approvedAssetAmount,
            pendingAssetAmount
        );
    }

    /// @inheritdoc IShareClassManager
    function approveRedeems(
        PoolId poolId,
        ShareClassId scId_,
        AssetId payoutAssetId,
        uint32 nowRedeemEpochId,
        uint128 approvedShareAmount,
        D18 pricePoolPerAsset
    ) external auth returns (uint128 pendingShareAmount) {
        require(exists(poolId, scId_), ShareClassNotFound());
        require(
            nowRedeemEpochId == nowRedeemEpoch(scId_, payoutAssetId),
            EpochNotInSequence(nowRedeemEpochId, nowRedeemEpoch(scId_, payoutAssetId))
        );

        // Limit in case approved > pending due to race condition of FM approval and async incoming requests
        pendingShareAmount = pendingRedeem[scId_][payoutAssetId];
        require(approvedShareAmount <= pendingShareAmount, InsufficientPending());
        require(approvedShareAmount > 0, ZeroApprovalAmount());

        // Update epoch data
        EpochRedeemAmounts storage epochAmounts = epochRedeemAmounts[scId_][payoutAssetId][nowRedeemEpochId];
        epochAmounts.approvedShareAmount = approvedShareAmount;
        epochAmounts.pendingShareAmount = pendingShareAmount;
        epochAmounts.pricePoolPerAsset = pricePoolPerAsset;

        // Reduce pending
        pendingRedeem[scId_][payoutAssetId] -= approvedShareAmount;
        pendingShareAmount -= approvedShareAmount;
        redeemEpochId[scId_][payoutAssetId] = nowRedeemEpochId;
        emit ApproveRedeems(poolId, scId_, payoutAssetId, nowRedeemEpochId, approvedShareAmount, pendingShareAmount);
    }

    /// @inheritdoc IShareClassManager
    function issueShares(
        PoolId poolId,
        ShareClassId scId_,
        AssetId depositAssetId,
        uint32 nowIssueEpochId,
        D18 navPoolPerShare
    ) external auth returns (uint128 issuedShareAmount, uint128 depositAssetAmount, uint128 depositPoolAmount) {
        require(exists(poolId, scId_), ShareClassNotFound());
        require(nowIssueEpochId <= depositEpochId[scId_][depositAssetId], EpochNotFound());
        require(
            nowIssueEpochId == nowIssueEpoch(scId_, depositAssetId),
            EpochNotInSequence(nowIssueEpochId, nowIssueEpoch(scId_, depositAssetId))
        );

        EpochInvestAmounts storage epochAmounts = epochInvestAmounts[scId_][depositAssetId][nowIssueEpochId];
        epochAmounts.navPoolPerShare = navPoolPerShare;

        issuedShareAmount = ConversionLib.assetToShareAmount(
            epochAmounts.approvedAssetAmount,
            hubRegistry.decimals(depositAssetId),
            hubRegistry.decimals(poolId),
            epochAmounts.pricePoolPerAsset,
            navPoolPerShare
        ).toUint128();

        metrics[scId_].totalIssuance += issuedShareAmount;
        epochAmounts.issuedAt = block.timestamp.toUint64();
        issueEpochId[scId_][depositAssetId] = nowIssueEpochId;

        depositAssetAmount = epochAmounts.approvedAssetAmount;
        depositPoolAmount = epochAmounts.approvedPoolAmount;

        emit IssueShares(
            poolId,
            scId_,
            depositAssetId,
            nowIssueEpochId,
            navPoolPerShare,
            _navAssetPerShare(epochAmounts.navPoolPerShare, epochAmounts.pricePoolPerAsset),
            issuedShareAmount
        );
    }

    /// @inheritdoc IShareClassManager
    function revokeShares(
        PoolId poolId,
        ShareClassId scId_,
        AssetId payoutAssetId,
        uint32 nowRevokeEpochId,
        D18 navPoolPerShare
    ) external auth returns (uint128 revokedShareAmount, uint128 payoutAssetAmount, uint128 payoutPoolAmount) {
        require(exists(poolId, scId_), ShareClassNotFound());
        require(nowRevokeEpochId <= redeemEpochId[scId_][payoutAssetId], EpochNotFound());
        require(
            nowRevokeEpochId == nowRevokeEpoch(scId_, payoutAssetId),
            EpochNotInSequence(nowRevokeEpochId, nowRevokeEpoch(scId_, payoutAssetId))
        );

        EpochRedeemAmounts storage epochAmounts = epochRedeemAmounts[scId_][payoutAssetId][nowRevokeEpochId];
        epochAmounts.navPoolPerShare = navPoolPerShare;

        require(epochAmounts.approvedShareAmount <= metrics[scId_].totalIssuance, RevokeMoreThanIssued());

        // NOTE: shares and pool currency have the same decimals - no conversion needed!
        payoutPoolAmount = navPoolPerShare.mulUint128(epochAmounts.approvedShareAmount);

        payoutAssetAmount = ConversionLib.poolToAssetAmount(
            payoutPoolAmount,
            hubRegistry.decimals(poolId),
            hubRegistry.decimals(payoutAssetId),
            epochAmounts.pricePoolPerAsset
        ).toUint128();
        revokedShareAmount = epochAmounts.approvedShareAmount;

        metrics[scId_].totalIssuance -= epochAmounts.approvedShareAmount;
        epochAmounts.payoutAssetAmount = payoutAssetAmount;
        epochAmounts.revokedAt = block.timestamp.toUint64();
        revokeEpochId[scId_][payoutAssetId] = nowRevokeEpochId;

        emit RevokeShares(
            poolId,
            scId_,
            payoutAssetId,
            nowRevokeEpochId,
            navPoolPerShare,
            _navAssetPerShare(epochAmounts.navPoolPerShare, epochAmounts.pricePoolPerAsset),
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
        require(userOrder.pending > 0, NoOrderFound());
        require(userOrder.lastUpdate <= issueEpochId[scId_][depositAssetId], IssuanceRequired());
        canClaimAgain = userOrder.lastUpdate < issueEpochId[scId_][depositAssetId];
        EpochInvestAmounts storage epochAmounts = epochInvestAmounts[scId_][depositAssetId][userOrder.lastUpdate];

        paymentAssetAmount = epochAmounts.approvedAssetAmount == 0
            ? 0
            : userOrder.pending.mulDiv(epochAmounts.approvedAssetAmount, epochAmounts.pendingAssetAmount).toUint128();

        // NOTE: Due to precision loss, the sum of claimable user amounts is leq than the amount of minted share class
        // tokens corresponding to the approved share amount (instead of equality). I.e., it is possible for an epoch to
        // have an excess of a share class tokens which cannot be claimed by anyone.
        // This excess is at most n-1 share tokens for an epoch with n claimable users.
        if (paymentAssetAmount > 0) {
            uint256 paymentPoolAmount = ConversionLib.convertWithPrice(
                paymentAssetAmount,
                hubRegistry.decimals(depositAssetId),
                hubRegistry.decimals(poolId),
                epochAmounts.pricePoolPerAsset
            );
            payoutShareAmount = epochAmounts.navPoolPerShare.reciprocalMulUint256(paymentPoolAmount).toUint128();

            userOrder.pending -= paymentAssetAmount;
        }

        emit ClaimDeposit(
            poolId,
            scId_,
            userOrder.lastUpdate,
            investor,
            depositAssetId,
            paymentAssetAmount,
            userOrder.pending,
            payoutShareAmount,
            epochAmounts.issuedAt
        );

        // If there is nothing to claim anymore we can short circuit to the latest epoch
        if (userOrder.pending == 0) {
            // The current epoch is always one step ahead of the stored one
            userOrder.lastUpdate = nowDepositEpoch(scId_, depositAssetId);
            canClaimAgain = false;
        } else {
            userOrder.lastUpdate += 1;
        }

        // If user claimed up to latest approval epoch, move queued to pending
        if (userOrder.lastUpdate == nowDepositEpoch(scId_, depositAssetId)) {
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
        require(userOrder.pending > 0, NoOrderFound());
        require(userOrder.lastUpdate <= revokeEpochId[scId_][payoutAssetId], RevocationRequired());
        canClaimAgain = userOrder.lastUpdate < revokeEpochId[scId_][payoutAssetId];

        EpochRedeemAmounts storage epochAmounts = epochRedeemAmounts[scId_][payoutAssetId][userOrder.lastUpdate];

        paymentShareAmount = epochAmounts.approvedShareAmount == 0
            ? 0
            : userOrder.pending.mulDiv(epochAmounts.approvedShareAmount, epochAmounts.pendingShareAmount).toUint128();

        // NOTE: Due to precision loss, the sum of claimable user amounts is leq than the amount of minted share class
        // tokens corresponding to the approved share amount (instead of equality). I.e., it is possible for an epoch to
        // have an excess of a share class tokens which cannot be claimed by anyone.
        // This excess is at most n-1 share tokens for an epoch with n claimable users.
        if (paymentShareAmount > 0) {
            payoutAssetAmount = ConversionLib.shareToAssetAmount(
                paymentShareAmount,
                hubRegistry.decimals(poolId),
                hubRegistry.decimals(payoutAssetId),
                epochAmounts.navPoolPerShare,
                epochAmounts.pricePoolPerAsset
            ).toUint128();

            userOrder.pending -= paymentShareAmount;
        }

        emit ClaimRedeem(
            poolId,
            scId_,
            userOrder.lastUpdate,
            investor,
            payoutAssetId,
            paymentShareAmount,
            userOrder.pending,
            payoutAssetAmount,
            epochAmounts.revokedAt
        );

        // If there is nothing to claim anymore we can short circuit the in between epochs
        if (userOrder.pending == 0) {
            // The current epoch is always one step ahead of the stored one
            userOrder.lastUpdate = nowRedeemEpoch(scId_, payoutAssetId);
            canClaimAgain = false;
        } else {
            userOrder.lastUpdate += 1;
        }

        if (userOrder.lastUpdate == nowRedeemEpoch(scId_, payoutAssetId)) {
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
    function nowIssueEpoch(ShareClassId scId_, AssetId depositAssetId) public view returns (uint32) {
        return issueEpochId[scId_][depositAssetId] + 1;
    }

    /// @inheritdoc IShareClassManager
    function nowRedeemEpoch(ShareClassId scId_, AssetId depositAssetId) public view returns (uint32) {
        return redeemEpochId[scId_][depositAssetId] + 1;
    }

    /// @inheritdoc IShareClassManager
    function nowRevokeEpoch(ShareClassId scId_, AssetId depositAssetId) public view returns (uint32) {
        return revokeEpochId[scId_][depositAssetId] + 1;
    }

    /// @inheritdoc IShareClassManager
    function maxDepositClaims(ShareClassId scId_, bytes32 investor, AssetId depositAssetId)
        public
        view
        returns (uint32)
    {
        return _maxClaims(depositRequest[scId_][depositAssetId][investor], depositEpochId[scId_][depositAssetId]);
    }

    /// @inheritdoc IShareClassManager
    function maxRedeemClaims(ShareClassId scId_, bytes32 investor, AssetId payoutAssetId)
        public
        view
        returns (uint32)
    {
        return _maxClaims(redeemRequest[scId_][payoutAssetId][investor], redeemEpochId[scId_][payoutAssetId]);
    }

    function _maxClaims(UserOrder memory userOrder, uint32 lastEpoch) private pure returns (uint32) {
        // User order either not set or not processed
        if (userOrder.pending == 0 || userOrder.lastUpdate > lastEpoch) {
            return 0;
        }

        return lastEpoch - userOrder.lastUpdate + 1;
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
        // NOTE: If we decrease the pending, we decrease usually by the full amount
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
            requestType == RequestType.Deposit ? depositEpochId[scId_][assetId] : redeemEpochId[scId_][assetId];
        uint32 currentEpoch = lastEpoch + 1;

        // Short circuit if user can mutate pending, i.e. last update happened after latest approval or is first update
        if (userOrder.lastUpdate == currentEpoch || userOrder.pending == 0 || lastEpoch == 0) {
            return false;
        }

        // Block increasing queued amount if cancelling is already queued
        // NOTE: Can only happen due to race condition as CV blocks requests if cancellation is in progress
        require(!(queued.isCancelling && amount > 0), CancellationQueued());

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
        pendingTotal = isIncrement ? pendingTotal + amount : pendingTotal - amount;
        pendingDeposit[scId_][assetId] = pendingTotal;

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
        pendingTotal = isIncrement ? pendingTotal + amount : pendingTotal - amount;
        pendingRedeem[scId_][assetId] = pendingTotal;

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

    function _navAssetPerShare(D18 navPoolPerShare, D18 pricePoolPerAsset) private pure returns (D18) {
        return navPoolPerShare / pricePoolPerAsset;
    }
}
