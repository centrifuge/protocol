// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "../misc/Auth.sol";
import {D18, d18} from "../misc/types/D18.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {PricingLib} from "../common/libraries/PricingLib.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";
import {IHubMessageSender} from "../common/interfaces/IGatewaySenders.sol";
import {IHubGatewayHandler} from "../common/interfaces/IGatewayHandlers.sol";
import {RequestCallbackMessageLib} from "../common/libraries/RequestCallbackMessageLib.sol";
import {RequestMessageLib, RequestType as RequestMessageType} from "../common/libraries/RequestMessageLib.sol";

import {IHubRegistry} from "../hub/interfaces/IHubRegistry.sol";
import {
    IHubRequestManager,
    EpochInvestAmounts,
    EpochRedeemAmounts,
    UserOrder,
    QueuedOrder,
    RequestType,
    EpochId
} from "../hub/interfaces/IHubRequestManager.sol";

/// @title  Hub Request Manager
/// @notice Manager for handling deposit/redeem requests, epochs, and fulfillment logic for share classes
contract HubRequestManager is Auth, IHubRequestManager {
    using MathLib for *;
    using CastLib for *;
    using BytesLib for bytes;
    using RequestMessageLib for *;
    using RequestCallbackMessageLib for *;

    IHubRegistry public immutable hubRegistry;

    address public hub;

    // Epochs
    mapping(ShareClassId scId => mapping(AssetId assetId => EpochId)) public epochId;
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(uint32 epochId_ => EpochInvestAmounts epoch)))
        public epochInvestAmounts;
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(uint32 epochId_ => EpochRedeemAmounts epoch)))
        public epochRedeemAmounts;

    // Pending requests
    mapping(ShareClassId scId => mapping(AssetId payoutAssetId => uint128 pending)) public pendingRedeem;
    mapping(ShareClassId scId => mapping(AssetId depositAssetId => uint128 pending)) public pendingDeposit;
    mapping(ShareClassId scId => mapping(AssetId payoutAssetId => mapping(bytes32 investor => UserOrder pending)))
        public redeemRequest;
    mapping(ShareClassId scId => mapping(AssetId depositAssetId => mapping(bytes32 investor => UserOrder pending)))
        public depositRequest;

    // Queued requests
    mapping(ShareClassId scId => mapping(AssetId payoutAssetId => mapping(bytes32 investor => QueuedOrder queued)))
        public queuedRedeemRequest;
    mapping(ShareClassId scId => mapping(AssetId depositAssetId => mapping(bytes32 investor => QueuedOrder queued)))
        public queuedDepositRequest;

    // Force cancel request safeguards
    mapping(ShareClassId scId => mapping(AssetId depositAssetId => mapping(bytes32 investor => bool cancelled))) public
        allowForceDepositCancel;
    mapping(ShareClassId scId => mapping(AssetId payoutAssetId => mapping(bytes32 investor => bool cancelled))) public
        allowForceRedeemCancel;

    constructor(IHubRegistry hubRegistry_, address deployer) Auth(deployer) {
        hubRegistry = hubRegistry_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'hub'
    function file(bytes32 what, address data) external auth {
        if (what == "hub") hub = data;
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming requests
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubRequestManager
    function request(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external auth {
        uint8 kind = uint8(RequestMessageLib.requestType(payload));

        if (kind == uint8(RequestMessageType.DepositRequest)) {
            RequestMessageLib.DepositRequest memory m = payload.deserializeDepositRequest();
            requestDeposit(poolId, scId, m.amount, m.investor, assetId);
        } else if (kind == uint8(RequestMessageType.RedeemRequest)) {
            RequestMessageLib.RedeemRequest memory m = payload.deserializeRedeemRequest();
            requestRedeem(poolId, scId, m.amount, m.investor, assetId);
        } else if (kind == uint8(RequestMessageType.CancelDepositRequest)) {
            RequestMessageLib.CancelDepositRequest memory m = payload.deserializeCancelDepositRequest();
            uint128 cancelledAssetAmount = cancelDepositRequest(poolId, scId, m.investor, assetId);

            // Cancellation might have been queued such that it will be executed in the future during claiming
            if (cancelledAssetAmount > 0) {
                IHubGatewayHandler(hub).requestCallback(
                    poolId,
                    scId,
                    assetId,
                    RequestCallbackMessageLib.FulfilledDepositRequest(m.investor, 0, 0, cancelledAssetAmount).serialize(
                    ),
                    0
                );
            }
        } else if (kind == uint8(RequestMessageType.CancelRedeemRequest)) {
            RequestMessageLib.CancelRedeemRequest memory m = payload.deserializeCancelRedeemRequest();
            uint128 cancelledShareAmount = cancelRedeemRequest(poolId, scId, m.investor, assetId);

            // Cancellation might have been queued such that it will be executed in the future during claiming
            if (cancelledShareAmount > 0) {
                IHubGatewayHandler(hub).requestCallback(
                    poolId,
                    scId,
                    assetId,
                    RequestCallbackMessageLib.FulfilledRedeemRequest(m.investor, 0, 0, cancelledShareAmount).serialize(),
                    0
                );
            }
        } else {
            revert UnknownRequestType();
        }
    }

    /// @inheritdoc IHubRequestManager
    function requestDeposit(PoolId poolId, ShareClassId scId_, uint128 amount, bytes32 investor, AssetId depositAssetId)
        public
        auth
    {
        // NOTE: Vaults ensure amount > 0
        _updatePending(poolId, scId_, amount, true, investor, depositAssetId, RequestType.Deposit);
    }

    /// @inheritdoc IHubRequestManager
    function cancelDepositRequest(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId depositAssetId)
        public
        auth
        returns (uint128 cancelledAssetAmount)
    {
        allowForceDepositCancel[scId_][depositAssetId][investor] = true;
        uint128 cancellingAmount = depositRequest[scId_][depositAssetId][investor].pending;

        return _updatePending(poolId, scId_, cancellingAmount, false, investor, depositAssetId, RequestType.Deposit);
    }

    /// @inheritdoc IHubRequestManager
    function requestRedeem(PoolId poolId, ShareClassId scId_, uint128 amount, bytes32 investor, AssetId payoutAssetId)
        public
        auth
    {
        // NOTE: Vaults ensure amount > 0
        _updatePending(poolId, scId_, amount, true, investor, payoutAssetId, RequestType.Redeem);
    }

    /// @inheritdoc IHubRequestManager
    function cancelRedeemRequest(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId payoutAssetId)
        public
        auth
        returns (uint128 cancelledShareAmount)
    {
        allowForceRedeemCancel[scId_][payoutAssetId][investor] = true;
        uint128 cancellingAmount = redeemRequest[scId_][payoutAssetId][investor].pending;

        return _updatePending(poolId, scId_, cancellingAmount, false, investor, payoutAssetId, RequestType.Redeem);
    }

    //----------------------------------------------------------------------------------------------
    // Manager actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubRequestManager
    function approveDeposits(
        PoolId poolId,
        ShareClassId scId_,
        AssetId depositAssetId,
        uint32 nowDepositEpochId,
        uint128 approvedAssetAmount,
        D18 pricePoolPerAsset
    ) external auth returns (uint256 cost) {
        require(
            nowDepositEpochId == nowDepositEpoch(scId_, depositAssetId),
            EpochNotInSequence(nowDepositEpochId, nowDepositEpoch(scId_, depositAssetId))
        );

        // Limit in case approved > pending due to race condition of FM approval and async incoming requests
        uint128 pendingAssetAmount = pendingDeposit[scId_][depositAssetId];
        require(approvedAssetAmount <= pendingAssetAmount, InsufficientPending());
        require(approvedAssetAmount > 0, ZeroApprovalAmount());

        uint128 approvedPoolAmount = PricingLib.convertWithPrice(
            approvedAssetAmount, hubRegistry.decimals(depositAssetId), hubRegistry.decimals(poolId), pricePoolPerAsset
        );

        // Update epoch data
        EpochInvestAmounts storage epochAmounts = epochInvestAmounts[scId_][depositAssetId][nowDepositEpochId];
        epochAmounts.approvedAssetAmount = approvedAssetAmount;
        epochAmounts.approvedPoolAmount = approvedPoolAmount;
        epochAmounts.pendingAssetAmount = pendingAssetAmount;
        epochAmounts.pricePoolPerAsset = pricePoolPerAsset;

        // Reduce pending
        pendingDeposit[scId_][depositAssetId] -= approvedAssetAmount;
        pendingAssetAmount -= approvedAssetAmount;

        epochId[scId_][depositAssetId].deposit = nowDepositEpochId;
        emit ApproveDeposits(
            poolId,
            scId_,
            depositAssetId,
            nowDepositEpochId,
            approvedPoolAmount,
            approvedAssetAmount,
            pendingAssetAmount
        );

        return IHubGatewayHandler(hub).requestCallback(
            poolId,
            scId_,
            depositAssetId,
            RequestCallbackMessageLib.ApprovedDeposits(approvedAssetAmount, pricePoolPerAsset.raw()).serialize(),
            0
        );
    }

    /// @inheritdoc IHubRequestManager
    function approveRedeems(
        PoolId poolId,
        ShareClassId scId_,
        AssetId payoutAssetId,
        uint32 nowRedeemEpochId,
        uint128 approvedShareAmount,
        D18 pricePoolPerAsset
    ) external auth {
        require(
            nowRedeemEpochId == nowRedeemEpoch(scId_, payoutAssetId),
            EpochNotInSequence(nowRedeemEpochId, nowRedeemEpoch(scId_, payoutAssetId))
        );

        // Limit in case approved > pending due to race condition of FM approval and async incoming requests
        uint128 pendingShareAmount = pendingRedeem[scId_][payoutAssetId];
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
        epochId[scId_][payoutAssetId].redeem = nowRedeemEpochId;
        emit ApproveRedeems(poolId, scId_, payoutAssetId, nowRedeemEpochId, approvedShareAmount, pendingShareAmount);
    }

    /// @inheritdoc IHubRequestManager
    function issueShares(
        PoolId poolId,
        ShareClassId scId_,
        AssetId depositAssetId,
        uint32 nowIssueEpochId,
        D18 navPoolPerShare,
        uint128 extraGasLimit
    ) external auth returns (uint256 cost) {
        require(nowIssueEpochId <= epochId[scId_][depositAssetId].deposit, EpochNotFound());
        require(
            nowIssueEpochId == nowIssueEpoch(scId_, depositAssetId),
            EpochNotInSequence(nowIssueEpochId, nowIssueEpoch(scId_, depositAssetId))
        );

        EpochInvestAmounts storage epochAmounts = epochInvestAmounts[scId_][depositAssetId][nowIssueEpochId];
        epochAmounts.navPoolPerShare = navPoolPerShare;

        uint128 issuedShareAmount = navPoolPerShare.isNotZero()
            ? PricingLib.assetToShareAmount(
                epochAmounts.approvedAssetAmount,
                hubRegistry.decimals(depositAssetId),
                hubRegistry.decimals(poolId),
                epochAmounts.pricePoolPerAsset,
                navPoolPerShare,
                MathLib.Rounding.Down
            )
            : 0;

        epochAmounts.issuedAt = block.timestamp.toUint64();
        epochId[scId_][depositAssetId].issue = nowIssueEpochId;

        emit IssueShares(
            poolId,
            scId_,
            depositAssetId,
            nowIssueEpochId,
            navPoolPerShare,
            epochAmounts.pricePoolPerAsset.isNotZero()
                ? PricingLib.priceAssetPerShare(epochAmounts.navPoolPerShare, epochAmounts.pricePoolPerAsset)
                : d18(0),
            issuedShareAmount
        );

        return IHubGatewayHandler(hub).requestCallback(
            poolId,
            scId_,
            depositAssetId,
            RequestCallbackMessageLib.IssuedShares(issuedShareAmount, navPoolPerShare.raw()).serialize(),
            extraGasLimit
        );
    }

    /// @inheritdoc IHubRequestManager
    function revokeShares(
        PoolId poolId,
        ShareClassId scId_,
        AssetId payoutAssetId,
        uint32 nowRevokeEpochId,
        D18 navPoolPerShare,
        uint128 extraGasLimit
    ) external auth returns (uint256 cost) {
        require(nowRevokeEpochId <= epochId[scId_][payoutAssetId].redeem, EpochNotFound());
        require(
            nowRevokeEpochId == nowRevokeEpoch(scId_, payoutAssetId),
            EpochNotInSequence(nowRevokeEpochId, nowRevokeEpoch(scId_, payoutAssetId))
        );

        EpochRedeemAmounts storage epochAmounts = epochRedeemAmounts[scId_][payoutAssetId][nowRevokeEpochId];
        epochAmounts.navPoolPerShare = navPoolPerShare;

        // NOTE: shares and pool currency have the same decimals - no conversion needed!
        uint128 payoutPoolAmount = navPoolPerShare.mulUint128(epochAmounts.approvedShareAmount, MathLib.Rounding.Down);

        uint128 payoutAssetAmount = epochAmounts.pricePoolPerAsset.isNotZero()
            ? PricingLib.shareToAssetAmount(
                epochAmounts.approvedShareAmount,
                hubRegistry.decimals(poolId),
                hubRegistry.decimals(payoutAssetId),
                epochAmounts.navPoolPerShare,
                epochAmounts.pricePoolPerAsset,
                MathLib.Rounding.Down
            )
            : 0;
        uint128 revokedShareAmount = epochAmounts.approvedShareAmount;

        epochAmounts.payoutAssetAmount = payoutAssetAmount;
        epochAmounts.revokedAt = block.timestamp.toUint64();
        epochId[scId_][payoutAssetId].revoke = nowRevokeEpochId;

        emit RevokeShares(
            poolId,
            scId_,
            payoutAssetId,
            nowRevokeEpochId,
            navPoolPerShare,
            epochAmounts.pricePoolPerAsset.isNotZero()
                ? PricingLib.priceAssetPerShare(epochAmounts.navPoolPerShare, epochAmounts.pricePoolPerAsset)
                : d18(0),
            epochAmounts.approvedShareAmount,
            payoutAssetAmount,
            payoutPoolAmount
        );

        return IHubGatewayHandler(hub).requestCallback(
            poolId,
            scId_,
            payoutAssetId,
            RequestCallbackMessageLib.RevokedShares(payoutAssetAmount, revokedShareAmount, navPoolPerShare.raw())
                .serialize(),
            extraGasLimit
        );
    }

    /// @inheritdoc IHubRequestManager
    function forceCancelDepositRequest(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId depositAssetId)
        external
        auth
        returns (uint256 cost)
    {
        require(allowForceDepositCancel[scId_][depositAssetId][investor], CancellationInitializationRequired());

        uint128 cancellingAmount = depositRequest[scId_][depositAssetId][investor].pending;
        uint128 cancelledAssetAmount =
            _updatePending(poolId, scId_, cancellingAmount, false, investor, depositAssetId, RequestType.Deposit);

        // Cancellation might have been queued such that it will be executed in the future during claiming
        if (cancelledAssetAmount > 0) {
            return IHubGatewayHandler(hub).requestCallback(
                poolId,
                scId_,
                depositAssetId,
                RequestCallbackMessageLib.FulfilledDepositRequest(investor, 0, 0, cancelledAssetAmount).serialize(),
                0
            );
        }
    }

    /// @inheritdoc IHubRequestManager
    function forceCancelRedeemRequest(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId payoutAssetId)
        external
        auth
        returns (uint256 cost)
    {
        require(allowForceRedeemCancel[scId_][payoutAssetId][investor], CancellationInitializationRequired());

        uint128 cancellingAmount = redeemRequest[scId_][payoutAssetId][investor].pending;
        uint128 cancelledShareAmount =
            _updatePending(poolId, scId_, cancellingAmount, false, investor, payoutAssetId, RequestType.Redeem);

        // Cancellation might have been queued such that it will be executed in the future during claiming
        if (cancelledShareAmount > 0) {
            return IHubGatewayHandler(hub).requestCallback(
                poolId,
                scId_,
                payoutAssetId,
                RequestCallbackMessageLib.FulfilledRedeemRequest(investor, 0, 0, cancelledShareAmount).serialize(),
                0
            );
        }
    }

    //----------------------------------------------------------------------------------------------
    // Claiming methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubRequestManager
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
        UserOrder storage userOrder = depositRequest[scId_][depositAssetId][investor];
        require(userOrder.pending > 0, NoOrderFound());
        require(userOrder.lastUpdate <= epochId[scId_][depositAssetId].issue, IssuanceRequired());
        canClaimAgain = userOrder.lastUpdate < epochId[scId_][depositAssetId].issue;
        EpochInvestAmounts storage epochAmounts = epochInvestAmounts[scId_][depositAssetId][userOrder.lastUpdate];

        paymentAssetAmount = epochAmounts.approvedAssetAmount == 0
            ? 0
            : userOrder.pending.mulDiv(epochAmounts.approvedAssetAmount, epochAmounts.pendingAssetAmount).toUint128();

        // NOTE: Due to precision loss, the sum of claimable user amounts is leq than the amount of minted share class
        // tokens corresponding to the approved share amount (instead of equality). I.e., it is possible for an epoch to
        // have an excess of a share class tokens which cannot be claimed by anyone.
        if (paymentAssetAmount > 0) {
            payoutShareAmount = epochAmounts.navPoolPerShare.isNotZero()
                ? PricingLib.assetToShareAmount(
                    paymentAssetAmount,
                    hubRegistry.decimals(depositAssetId),
                    hubRegistry.decimals(poolId),
                    epochAmounts.pricePoolPerAsset,
                    epochAmounts.navPoolPerShare,
                    MathLib.Rounding.Down
                )
                : 0;

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

    /// @inheritdoc IHubRequestManager
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
        UserOrder storage userOrder = redeemRequest[scId_][payoutAssetId][investor];
        require(userOrder.pending > 0, NoOrderFound());
        require(userOrder.lastUpdate <= epochId[scId_][payoutAssetId].revoke, RevocationRequired());
        canClaimAgain = userOrder.lastUpdate < epochId[scId_][payoutAssetId].revoke;

        EpochRedeemAmounts storage epochAmounts = epochRedeemAmounts[scId_][payoutAssetId][userOrder.lastUpdate];

        paymentShareAmount = epochAmounts.approvedShareAmount == 0
            ? 0
            : userOrder.pending.mulDiv(epochAmounts.approvedShareAmount, epochAmounts.pendingShareAmount).toUint128();

        // NOTE: Due to precision loss, the sum of claimable user amounts is leq than the amount of payout asset
        // corresponding to the approved share class (instead of equality). I.e., it is possible for an epoch to
        // have an excess of payout assets which cannot be claimed by anyone.
        if (paymentShareAmount > 0) {
            payoutAssetAmount = epochAmounts.pricePoolPerAsset.isNotZero()
                ? PricingLib.shareToAssetAmount(
                    paymentShareAmount,
                    hubRegistry.decimals(poolId),
                    hubRegistry.decimals(payoutAssetId),
                    epochAmounts.navPoolPerShare,
                    epochAmounts.pricePoolPerAsset,
                    MathLib.Rounding.Down
                )
                : 0;

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

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubRequestManager
    function nowDepositEpoch(ShareClassId scId_, AssetId depositAssetId) public view returns (uint32) {
        return epochId[scId_][depositAssetId].deposit + 1;
    }

    /// @inheritdoc IHubRequestManager
    function nowIssueEpoch(ShareClassId scId_, AssetId depositAssetId) public view returns (uint32) {
        return epochId[scId_][depositAssetId].issue + 1;
    }

    /// @inheritdoc IHubRequestManager
    function nowRedeemEpoch(ShareClassId scId_, AssetId depositAssetId) public view returns (uint32) {
        return epochId[scId_][depositAssetId].redeem + 1;
    }

    /// @inheritdoc IHubRequestManager
    function nowRevokeEpoch(ShareClassId scId_, AssetId depositAssetId) public view returns (uint32) {
        return epochId[scId_][depositAssetId].revoke + 1;
    }

    /// @inheritdoc IHubRequestManager
    function maxDepositClaims(ShareClassId scId_, bytes32 investor, AssetId depositAssetId)
        public
        view
        returns (uint32)
    {
        return _maxClaims(depositRequest[scId_][depositAssetId][investor], epochId[scId_][depositAssetId].deposit);
    }

    /// @inheritdoc IHubRequestManager
    function maxRedeemClaims(ShareClassId scId_, bytes32 investor, AssetId payoutAssetId)
        public
        view
        returns (uint32)
    {
        return _maxClaims(redeemRequest[scId_][payoutAssetId][investor], epochId[scId_][payoutAssetId].revoke);
    }

    function _maxClaims(UserOrder memory userOrder, uint32 lastEpoch) internal pure returns (uint32) {
        // User order either not set or not processed
        if (userOrder.pending == 0 || userOrder.lastUpdate > lastEpoch) {
            return 0;
        }

        return lastEpoch - userOrder.lastUpdate + 1;
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    function _postClaimUpdateQueued(
        PoolId poolId,
        ShareClassId scId_,
        bytes32 investor,
        AssetId assetId,
        UserOrder storage userOrder,
        RequestType requestType
    ) internal returns (uint128 cancelledAmount) {
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
    ) internal returns (uint128 cancelledAmount) {
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
        //       We keep subtraction of amount over setting to zero on purpose to not limit future higher level logic
        userOrder.pending = isIncrement ? userOrder.pending + amount : userOrder.pending - amount;

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
    ) internal returns (bool skipPendingUpdate) {
        uint32 currentEpoch =
            requestType == RequestType.Deposit ? nowDepositEpoch(scId_, assetId) : nowRedeemEpoch(scId_, assetId);

        // Short circuit if user can mutate pending, i.e. last update happened after latest approval or is first update
        if (_canMutatePending(userOrder, currentEpoch)) {
            return false;
        }

        // Block increasing queued amount if cancelling is already queued
        // NOTE: Can only happen due to race condition as Vaults blocks requests if cancellation is in progress
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
    ) internal {
        uint128 pendingTotal = pendingDeposit[scId_][assetId];
        pendingTotal = isIncrement ? pendingTotal + amount : pendingTotal - amount;
        pendingDeposit[scId_][assetId] = pendingTotal;

        emit UpdateDepositRequest(
            poolId,
            scId_,
            assetId,
            nowDepositEpoch(scId_, assetId),
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
    ) internal {
        uint128 pendingTotal = pendingRedeem[scId_][assetId];
        pendingTotal = isIncrement ? pendingTotal + amount : pendingTotal - amount;
        pendingRedeem[scId_][assetId] = pendingTotal;

        emit UpdateRedeemRequest(
            poolId,
            scId_,
            assetId,
            nowRedeemEpoch(scId_, assetId),
            investor,
            userOrder.pending,
            pendingTotal,
            queued.amount,
            queued.isCancelling
        );
    }

    /// @dev A user cannot mutate their pending amount at all times because it affects the total pending amount. It is
    ///     restricted to the following three conditions:
    ///         1. It's the first epoch (currentEpoch <= 1), which implies userOrder.lastUpdate == 0
    ///         2. User has no pending amount (userOrder.pending == 0)
    ///         3. User's last update is not behind the current epoch (userOrder.lastUpdate >= currentEpoch)
    function _canMutatePending(UserOrder memory userOrder, uint32 currentEpoch) internal pure returns (bool) {
        return currentEpoch <= 1 || userOrder.pending == 0 || userOrder.lastUpdate >= currentEpoch;
    }
}
