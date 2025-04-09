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

    /// Storage
    uint32 internal transient _epochIncrement;
    IHubRegistry public hubRegistry;
    mapping(bytes32 salt => bool) public salts;
    mapping(PoolId poolId => uint32) public epochId;
    mapping(PoolId poolId => uint32) public shareClassCount;
    mapping(ShareClassId scId => ShareClassMetrics) public metrics;
    mapping(ShareClassId scId => ShareClassMetadata) public metadata;
    mapping(PoolId poolId => mapping(ShareClassId => bool)) public shareClassIds;
    mapping(ShareClassId scId => mapping(AssetId assetId => EpochPointers)) public epochPointers;
    mapping(ShareClassId scId => mapping(AssetId payoutAssetId => uint128 pending)) public pendingRedeem;
    mapping(ShareClassId scId => mapping(AssetId paymentAssetId => uint128 pending)) public pendingDeposit;
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(uint32 epochId_ => EpochAmounts epoch))) public
        epochAmounts;
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

        // Initialize epoch with 1 iff first class was added
        if (index == 1) {
            epochId[poolId] = 1;
        }

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
        uint128 maxApproval,
        AssetId paymentAssetId,
        IERC7726 valuation
    ) external auth returns (uint128 approvedAssetAmount, uint128 approvedPoolAmount) {
        require(exists(poolId, scId_), ShareClassNotFound());

        // Advance epochId if it has not been advanced within this transaction (e.g. in case of multiCall context)
        uint32 approvalEpochId = _advanceEpoch(poolId);

        // Block approvals for the same asset in the same epoch
        require(epochPointers[scId_][paymentAssetId].latestDepositApproval != approvalEpochId, AlreadyApproved());

        // Limit in case approved > pending due to race condition of FM approval and async incoming requests
        uint128 _pendingDeposit = pendingDeposit[scId_][paymentAssetId];
        approvedAssetAmount = maxApproval.min(_pendingDeposit).toUint128();
        require(approvedAssetAmount > 0, ZeroApprovalAmount());

        // Increase approved
        address poolCurrency = hubRegistry.currency(poolId).addr();
        approvedPoolAmount =
            (IERC7726(valuation).getQuote(approvedAssetAmount, paymentAssetId.addr(), poolCurrency)).toUint128();

        // Update epoch data
        EpochAmounts storage epochAmounts_ = epochAmounts[scId_][paymentAssetId][approvalEpochId];
        epochAmounts_.depositApproved = approvedAssetAmount;
        epochAmounts_.depositPool = approvedPoolAmount;
        epochAmounts_.depositPending = _pendingDeposit;
        epochPointers[scId_][paymentAssetId].latestDepositApproval = approvalEpochId;

        // Reduce pending
        pendingDeposit[scId_][paymentAssetId] -= approvedAssetAmount;
        _pendingDeposit -= approvedAssetAmount;

        emit ApproveDeposits(
            poolId, scId_, approvalEpochId, paymentAssetId, approvedPoolAmount, approvedAssetAmount, _pendingDeposit
        );
    }

    /// @inheritdoc IShareClassManager
    function approveRedeems(PoolId poolId, ShareClassId scId_, uint128 maxApproval, AssetId payoutAssetId)
        external
        auth
        returns (uint128 approvedShareAmount, uint128 pendingShareAmount)
    {
        require(exists(poolId, scId_), ShareClassNotFound());

        // Advance epochId if it has not been advanced within this transaction (e.g. in case of multiCall context)
        uint32 approvalEpochId = _advanceEpoch(poolId);

        // Block approvals for the same asset in the same epoch
        require(epochPointers[scId_][payoutAssetId].latestRedeemApproval != approvalEpochId, AlreadyApproved());

        // Limit in case approved > pending due to race condition of FM approval and async incoming requests
        pendingShareAmount = pendingRedeem[scId_][payoutAssetId];
        approvedShareAmount = maxApproval.min(pendingShareAmount).toUint128();
        require(approvedShareAmount > 0, ZeroApprovalAmount());

        // Update epoch data
        EpochAmounts storage epochAmounts_ = epochAmounts[scId_][payoutAssetId][approvalEpochId];
        epochAmounts_.redeemApproved = approvedShareAmount;
        epochAmounts_.redeemPending = pendingShareAmount;

        // Reduce pending
        pendingRedeem[scId_][payoutAssetId] -= approvedShareAmount;
        pendingShareAmount -= approvedShareAmount;

        epochPointers[scId_][payoutAssetId].latestRedeemApproval = approvalEpochId;

        emit ApproveRedeems(poolId, scId_, approvalEpochId, payoutAssetId, approvedShareAmount, pendingShareAmount);
    }

    /// @inheritdoc IShareClassManager
    function issueShares(PoolId poolId, ShareClassId scId_, AssetId depositAssetId, D18 navPerShare) external auth {
        EpochPointers storage epochPointers_ = epochPointers[scId_][depositAssetId];
        require(epochPointers_.latestDepositApproval > epochPointers_.latestIssuance, ApprovalRequired());

        issueSharesUntilEpoch(poolId, scId_, depositAssetId, navPerShare, epochPointers_.latestDepositApproval);
    }

    /// @inheritdoc IShareClassManager
    function issueSharesUntilEpoch(
        PoolId poolId,
        ShareClassId scId_,
        AssetId depositAssetId,
        D18 navPerShare,
        uint32 endEpochId
    ) public auth {
        require(exists(poolId, scId_), ShareClassNotFound());
        require(endEpochId < epochId[poolId], EpochNotFound());

        ShareClassMetrics memory m = metrics[scId_];
        (uint128 totalIssuance, D18 navPerShare_) = (m.totalIssuance, m.navPerShare);

        // First issuance is epoch 1 due to also initializing epochs with 1
        // Subsequent issuances equal latest pointer plus one
        uint32 startEpochId = epochPointers[scId_][depositAssetId].latestIssuance + 1;

        for (uint32 epochId_ = startEpochId; epochId_ <= endEpochId; epochId_++) {
            // Skip redeem epochs
            if (epochAmounts[scId_][depositAssetId][epochId_].depositApproved == 0) {
                continue;
            }

            uint128 issuedShareAmount =
                navPerShare.reciprocalMulUint128(epochAmounts[scId_][depositAssetId][epochId_].depositPool);
            epochAmounts[scId_][depositAssetId][epochId_].depositShares = issuedShareAmount;
            totalIssuance += issuedShareAmount;
            uint128 nav = navPerShare.mulUint128(totalIssuance);

            emit IssueShares(poolId, scId_, epochId_, nav, navPerShare, totalIssuance, issuedShareAmount);
        }

        epochPointers[scId_][depositAssetId].latestIssuance = endEpochId;
        metrics[scId_] = ShareClassMetrics(totalIssuance, navPerShare_);
    }

    /// @inheritdoc IShareClassManager
    function revokeShares(PoolId poolId, ShareClassId scId_, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation)
        external
        auth
        returns (uint128 payoutAssetAmount, uint128 payoutPoolAmount)
    {
        EpochPointers storage epochPointers_ = epochPointers[scId_][payoutAssetId];
        require(epochPointers_.latestRedeemApproval > epochPointers_.latestRevocation, ApprovalRequired());

        return revokeSharesUntilEpoch(
            poolId, scId_, payoutAssetId, navPerShare, valuation, epochPointers_.latestRedeemApproval
        );
    }

    /// @inheritdoc IShareClassManager
    function revokeSharesUntilEpoch(
        PoolId poolId,
        ShareClassId scId_,
        AssetId payoutAssetId,
        D18 navPerShare,
        IERC7726 valuation,
        uint32 endEpochId
    ) public auth returns (uint128 payoutAssetAmount, uint128 payoutPoolAmount) {
        require(exists(poolId, scId_), ShareClassNotFound());
        require(endEpochId < epochId[poolId], EpochNotFound());

        ShareClassMetrics storage metrics_ = metrics[scId_];
        uint128 totalIssuance = metrics_.totalIssuance;
        address poolCurrency = hubRegistry.currency(poolId).addr();

        // First issuance is epoch 1 due to also initializing epochs with 1
        // Subsequent issuances equal latest pointer plus one
        uint32 startEpochId = epochPointers[scId_][payoutAssetId].latestRevocation + 1;

        for (uint32 epochId_ = startEpochId; epochId_ <= endEpochId; epochId_++) {
            EpochAmounts storage epochAmounts_ = epochAmounts[scId_][payoutAssetId][epochId_];

            // Skip deposit epochs
            if (epochAmounts_.redeemApproved == 0) {
                continue;
            }

            require(epochAmounts_.redeemApproved <= totalIssuance, RevokeMoreThanIssued());

            payoutPoolAmount += _revokeEpochShares(
                poolId,
                scId_,
                payoutAssetId,
                navPerShare,
                valuation,
                poolCurrency,
                epochAmounts_,
                totalIssuance,
                epochId_
            );
            payoutAssetAmount += epochAmounts_.redeemAssets;
            totalIssuance -= epochAmounts_.redeemApproved;
        }

        epochPointers[scId_][payoutAssetId].latestRevocation = endEpochId;
        metrics[scId_].totalIssuance = totalIssuance;
    }

    /// @inheritdoc IShareClassManager
    function claimDeposit(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId depositAssetId)
        external
        auth
        returns (uint128 payoutShareAmount, uint128 paymentAssetAmount, uint128 cancelledAmount)
    {
        return claimDepositUntilEpoch(
            poolId, scId_, investor, depositAssetId, epochPointers[scId_][depositAssetId].latestIssuance
        );
    }

    /// @inheritdoc IShareClassManager
    function claimDepositUntilEpoch(
        PoolId poolId,
        ShareClassId scId_,
        bytes32 investor,
        AssetId depositAssetId,
        uint32 endEpochId
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
    function claimRedeem(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId payoutAssetId)
        external
        auth
        returns (uint128 payoutAssetAmount, uint128 paymentShareAmount, uint128 cancelledShareAmount)
    {
        return claimRedeemUntilEpoch(
            poolId, scId_, investor, payoutAssetId, epochPointers[scId_][payoutAssetId].latestRevocation
        );
    }

    /// @inheritdoc IShareClassManager
    function claimRedeemUntilEpoch(
        PoolId poolId,
        ShareClassId scId_,
        bytes32 investor,
        AssetId payoutAssetId,
        uint32 endEpochId
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
    function increaseShareClassIssuance(PoolId poolId, ShareClassId scId_, D18 navPerShare, uint128 amount)
        external
        auth
    {
        require(exists(poolId, scId_), ShareClassNotFound());

        uint128 newIssuance = metrics[scId_].totalIssuance + amount;
        metrics[scId_].totalIssuance = newIssuance;

        emit IssueShares(poolId, scId_, epochId[poolId], navPerShare.mulUint128(newIssuance), navPerShare, newIssuance, amount);
    }

    /// @inheritdoc IShareClassManager
    function decreaseShareClassIssuance(PoolId poolId, ShareClassId scId_, D18 navPerShare, uint128 amount)
        external
        auth
    {
        require(exists(poolId, scId_), ShareClassNotFound());
        require(metrics[scId_].totalIssuance >= amount, DecreaseMoreThanIssued());

        uint128 newIssuance = metrics[scId_].totalIssuance - amount;
        metrics[scId_].totalIssuance = newIssuance;

        emit RevokeShares(poolId, scId_, epochId[poolId], navPerShare.mulUint128(newIssuance), navPerShare, newIssuance, amount, 0);
    }

    /// @inheritdoc IShareClassManager
    function updateShareClass(PoolId poolId, ShareClassId scId_, D18 navPerShare, bytes calldata data) external auth returns (uint128, D18) {
        require(exists(poolId, scId_), ShareClassNotFound());

        ShareClassMetrics storage m = metrics[scId_];
        m.navPerShare = navPerShare;
        emit UpdateShareClass(poolId, scId_, navPerShare.mulUint128(m.totalIssuance), navPerShare, m.totalIssuance, data);

        return (m.totalIssuance, navPerShare);
    }

    /// @inheritdoc IShareClassManager
    function shareClassPrice(PoolId poolId, ShareClassId scId_) external view returns (uint128, D18) {
        require(exists(poolId, scId_), ShareClassNotFound());

        ShareClassMetrics memory m = metrics[scId_];
        return (m.totalIssuance, m.navPerShare);
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
    function update(PoolId, bytes calldata) external pure {
        // No-op on purpose to allow higher level contract calls to this
    }

    /// @notice Revokes shares for a single epoch, updates epoch ratio and emits event.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId_ Identifier of the share class
    /// @param payoutAssetId Identifier of the payout asset
    /// @param navPerShare Total value of assets of the pool and share class per share
    /// @param valuation Source of truth for quotas, e.g. the price of a pool amount in payout asset
    /// @param poolCurrency The address of the pool currency
    /// @param epochAmounts_ Epoch ratio storage for the amount of revoked share class tokens and the corresponding
    /// amount
    /// in payout asset
    /// @param totalIssuance Total issuance of share class tokens before revoking
    /// @param epochId_ Identifier of the epoch for which we revoke
    /// @return payoutPoolAmount Converted amount of pool currency based on number of revoked shares
    function _revokeEpochShares(
        PoolId poolId,
        ShareClassId scId_,
        AssetId payoutAssetId,
        D18 navPerShare,
        IERC7726 valuation,
        address poolCurrency,
        EpochAmounts storage epochAmounts_,
        uint128 totalIssuance,
        uint32 epochId_
    ) private returns (uint128 payoutPoolAmount) {
        payoutPoolAmount = navPerShare.mulUint128(epochAmounts_.redeemApproved);
        epochAmounts_.redeemAssets =
            IERC7726(valuation).getQuote(payoutPoolAmount, poolCurrency, payoutAssetId.addr()).toUint128();

        uint128 newIssuance = totalIssuance - epochAmounts_.redeemApproved;
        uint128 nav = navPerShare.mulUint128(newIssuance);
        emit RevokeShares(
            poolId,
            scId_,
            epochId_,
            nav,
            navPerShare,
            newIssuance,
            epochAmounts_.redeemApproved,
            epochAmounts_.redeemAssets
        );
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

        require(salt != bytes32(0), InvalidSalt());
        // Either the salt has not changed, or the salt was never used before by any share class token
        require(salt == metadata[scId_].salt || !salts[salt], AlreadyUsedSalt());
        salts[salt] = true;

        metadata[scId_] = ShareClassMetadata(name, symbol, salt);
    }

    /// @notice Advances the current epoch of the given pool if it has not been incremented within the multicall. If the
    /// epoch has already been incremented, we don't bump it again to allow deposit and redeem approvals to point to the
    /// same epoch id. Emits NewEpoch event if the epoch is advanced.
    ///
    /// @param poolId Identifier of the pool for which we want to advance an epoch.
    /// @return epochIdCurrentBlock Identifier of the current epoch. E.g., if the epoch advanced from i to i+1, i is
    /// returned.
    function _advanceEpoch(PoolId poolId) private returns (uint32 epochIdCurrentBlock) {
        uint32 epochId_ = epochId[poolId];

        // Epoch doesn't necessarily advance, e.g. in case of multiple approvals inside the same multiCall
        if (_epochIncrement == 0) {
            _epochIncrement = 1;
            uint32 newEpochId = epochId_ + 1;
            epochId[poolId] = newEpochId;

            emit NewEpoch(poolId, newEpochId);

            return epochId_;
        } else {
            return uint32(uint128(epochId_ - 1).max(1));
        }
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
