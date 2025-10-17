// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RequestCallbackMessageLib} from "./libraries/RequestCallbackMessageLib.sol";
import {RequestMessageLib, RequestType as RequestMessageType} from "./libraries/RequestMessageLib.sol";
import {
    IBatchRequestManager,
    EpochInvestAmounts,
    EpochRedeemAmounts,
    UserOrder,
    QueuedOrder,
    RequestType,
    EpochId
} from "./interfaces/IBatchRequestManager.sol";

import {Auth} from "../misc/Auth.sol";
import {D18, d18} from "../misc/types/D18.sol";
import {IAuth} from "../misc/interfaces/IAuth.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {IERC165} from "../misc/interfaces/IERC165.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {AssetId} from "../core/types/AssetId.sol";
import {PricingLib} from "../core/libraries/PricingLib.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {IGateway} from "../core/messaging/interfaces/IGateway.sol";
import {BatchedMulticall} from "../core/utils/BatchedMulticall.sol";
import {IHubRegistry} from "../core/hub/interfaces/IHubRegistry.sol";
import {IHubRequestManagerCallback} from "../core/hub/interfaces/IHubRequestManagerCallback.sol";
import {IHubRequestManager, IHubRequestManagerNotifications} from "../core/hub/interfaces/IHubRequestManager.sol";

/// @title  Batch Request Manager
/// @notice Manager for handling deposit/redeem requests, epochs, and fulfillment logic for share classes
contract BatchRequestManager is Auth, BatchedMulticall, IBatchRequestManager {
    using MathLib for *;
    using CastLib for *;
    using BytesLib for bytes;
    using RequestMessageLib for *;
    using RequestCallbackMessageLib for *;

    IHubRequestManagerCallback public hub;
    IHubRegistry public immutable hubRegistry;

    // Epochs
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => EpochId))) public epochId;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(uint32 epochId_ => EpochInvestAmounts))))
        public epochInvestAmounts;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(uint32 epochId_ => EpochRedeemAmounts))))
        public epochRedeemAmounts;

    // Pending requests
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => uint128))) public pendingRedeem;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => uint128))) public pendingDeposit;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(bytes32 investor => UserOrder)))) public
        redeemRequest;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(bytes32 investor => UserOrder)))) public
        depositRequest;

    // Queued requests
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(bytes32 investor => QueuedOrder)))) public
        queuedRedeemRequest;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(bytes32 investor => QueuedOrder)))) public
        queuedDepositRequest;

    // Force cancel request safeguards
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(bytes32 investor => bool)))) public
        allowForceDepositCancel;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(bytes32 investor => bool)))) public
        allowForceRedeemCancel;

    constructor(IHubRegistry hubRegistry_, IGateway gateway_, address deployer)
        Auth(deployer)
        BatchedMulticall(gateway_)
    {
        hubRegistry = hubRegistry_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// Accepts a `bytes32` representation of 'hub'
    function file(bytes32 what, address data) external auth {
        if (what == "hub") hub = IHubRequestManagerCallback(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    modifier isManager(PoolId poolId) {
        require(hubRegistry.manager(poolId, msgSender()), IAuth.NotAuthorized());
        _;
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
                hub.requestCallback(
                    poolId,
                    scId,
                    assetId,
                    RequestCallbackMessageLib.FulfilledDepositRequest(m.investor, 0, 0, cancelledAssetAmount)
                        .serialize(),
                    0,
                    address(0) // Refund is not used because we're in unpaid mode with no payment
                );
            }
        } else if (kind == uint8(RequestMessageType.CancelRedeemRequest)) {
            RequestMessageLib.CancelRedeemRequest memory m = payload.deserializeCancelRedeemRequest();
            uint128 cancelledShareAmount = cancelRedeemRequest(poolId, scId, m.investor, assetId);

            // Cancellation might have been queued such that it will be executed in the future during claiming
            if (cancelledShareAmount > 0) {
                hub.requestCallback(
                    poolId,
                    scId,
                    assetId,
                    RequestCallbackMessageLib.FulfilledRedeemRequest(m.investor, 0, 0, cancelledShareAmount)
                        .serialize(),
                    0,
                    address(0) // Refund is not used because we're in unpaid mode with no payment
                );
            }
        } else {
            revert UnknownRequestType();
        }
    }

    /// @inheritdoc IBatchRequestManager
    function requestDeposit(
        PoolId poolId,
        ShareClassId scId_,
        uint128 amount,
        bytes32 investor,
        AssetId depositAssetId
    ) public auth {
        // NOTE: Vaults ensure amount > 0
        _updatePending(poolId, scId_, amount, true, investor, depositAssetId, RequestType.Deposit);
    }

    /// @inheritdoc IBatchRequestManager
    function cancelDepositRequest(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId depositAssetId)
        public
        auth
        returns (uint128 cancelledAssetAmount)
    {
        allowForceDepositCancel[poolId][scId_][depositAssetId][investor] = true;
        uint128 cancellingAmount = depositRequest[poolId][scId_][depositAssetId][investor].pending;

        return _updatePending(poolId, scId_, cancellingAmount, false, investor, depositAssetId, RequestType.Deposit);
    }

    /// @inheritdoc IBatchRequestManager
    function requestRedeem(PoolId poolId, ShareClassId scId_, uint128 amount, bytes32 investor, AssetId payoutAssetId)
        public
        auth
    {
        // NOTE: Vaults ensure amount > 0
        _updatePending(poolId, scId_, amount, true, investor, payoutAssetId, RequestType.Redeem);
    }

    /// @inheritdoc IBatchRequestManager
    function cancelRedeemRequest(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId payoutAssetId)
        public
        auth
        returns (uint128 cancelledShareAmount)
    {
        allowForceRedeemCancel[poolId][scId_][payoutAssetId][investor] = true;
        uint128 cancellingAmount = redeemRequest[poolId][scId_][payoutAssetId][investor].pending;

        return _updatePending(poolId, scId_, cancellingAmount, false, investor, payoutAssetId, RequestType.Redeem);
    }

    //----------------------------------------------------------------------------------------------
    // Manager actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBatchRequestManager
    function approveDeposits(
        PoolId poolId,
        ShareClassId scId_,
        AssetId depositAssetId,
        uint32 nowDepositEpochId,
        uint128 approvedAssetAmount,
        D18 pricePoolPerAsset,
        address refund
    ) external payable isManager(poolId) {
        require(
            nowDepositEpochId == nowDepositEpoch(poolId, scId_, depositAssetId),
            EpochNotInSequence(nowDepositEpochId, nowDepositEpoch(poolId, scId_, depositAssetId))
        );

        // Limit in case approved > pending due to race condition of FM approval and async incoming requests
        uint128 pendingAssetAmount = pendingDeposit[poolId][scId_][depositAssetId];
        require(approvedAssetAmount <= pendingAssetAmount, InsufficientPending());
        require(approvedAssetAmount > 0, ZeroApprovalAmount());

        uint128 approvedPoolAmount = PricingLib.convertWithPrice(
            approvedAssetAmount, hubRegistry.decimals(depositAssetId), hubRegistry.decimals(poolId), pricePoolPerAsset
        );

        // Update epoch data
        EpochInvestAmounts storage epochAmounts = epochInvestAmounts[poolId][scId_][depositAssetId][nowDepositEpochId];
        epochAmounts.approvedAssetAmount = approvedAssetAmount;
        epochAmounts.approvedPoolAmount = approvedPoolAmount;
        epochAmounts.pendingAssetAmount = pendingAssetAmount;
        epochAmounts.pricePoolPerAsset = pricePoolPerAsset;

        // Reduce pending
        pendingDeposit[poolId][scId_][depositAssetId] -= approvedAssetAmount;
        pendingAssetAmount -= approvedAssetAmount;

        epochId[poolId][scId_][depositAssetId].deposit = nowDepositEpochId;
        emit ApproveDeposits(
            poolId,
            scId_,
            depositAssetId,
            nowDepositEpochId,
            approvedPoolAmount,
            approvedAssetAmount,
            pendingAssetAmount
        );

        bytes memory callback =
            RequestCallbackMessageLib.ApprovedDeposits(approvedAssetAmount, pricePoolPerAsset.raw()).serialize();
        hub.requestCallback{value: msgValue()}(poolId, scId_, depositAssetId, callback, 0, refund);
    }

    /// @inheritdoc IBatchRequestManager
    function approveRedeems(
        PoolId poolId,
        ShareClassId scId_,
        AssetId payoutAssetId,
        uint32 nowRedeemEpochId,
        uint128 approvedShareAmount,
        D18 pricePoolPerAsset
    ) external payable isManager(poolId) {
        require(
            nowRedeemEpochId == nowRedeemEpoch(poolId, scId_, payoutAssetId),
            EpochNotInSequence(nowRedeemEpochId, nowRedeemEpoch(poolId, scId_, payoutAssetId))
        );

        // Limit in case approved > pending due to race condition of FM approval and async incoming requests
        uint128 pendingShareAmount = pendingRedeem[poolId][scId_][payoutAssetId];
        require(approvedShareAmount <= pendingShareAmount, InsufficientPending());
        require(approvedShareAmount > 0, ZeroApprovalAmount());

        // Update epoch data
        EpochRedeemAmounts storage epochAmounts = epochRedeemAmounts[poolId][scId_][payoutAssetId][nowRedeemEpochId];
        epochAmounts.approvedShareAmount = approvedShareAmount;
        epochAmounts.pendingShareAmount = pendingShareAmount;
        epochAmounts.pricePoolPerAsset = pricePoolPerAsset;

        // Reduce pending
        pendingRedeem[poolId][scId_][payoutAssetId] -= approvedShareAmount;
        pendingShareAmount -= approvedShareAmount;
        epochId[poolId][scId_][payoutAssetId].redeem = nowRedeemEpochId;
        emit ApproveRedeems(poolId, scId_, payoutAssetId, nowRedeemEpochId, approvedShareAmount, pendingShareAmount);
    }

    /// @inheritdoc IBatchRequestManager
    function issueShares(
        PoolId poolId,
        ShareClassId scId_,
        AssetId depositAssetId,
        uint32 nowIssueEpochId,
        D18 pricePoolPerShare,
        uint128 extraGasLimit,
        address refund
    ) external payable isManager(poolId) {
        require(nowIssueEpochId <= epochId[poolId][scId_][depositAssetId].deposit, EpochNotFound());
        require(
            nowIssueEpochId == nowIssueEpoch(poolId, scId_, depositAssetId),
            EpochNotInSequence(nowIssueEpochId, nowIssueEpoch(poolId, scId_, depositAssetId))
        );

        EpochInvestAmounts storage epochAmounts = epochInvestAmounts[poolId][scId_][depositAssetId][nowIssueEpochId];
        epochAmounts.pricePoolPerShare = pricePoolPerShare;

        uint128 issuedShareAmount = pricePoolPerShare.isNotZero()
            ? PricingLib.assetToShareAmount(
                epochAmounts.approvedAssetAmount,
                hubRegistry.decimals(depositAssetId),
                hubRegistry.decimals(poolId),
                epochAmounts.pricePoolPerAsset,
                pricePoolPerShare,
                MathLib.Rounding.Down
            )
            : 0;

        epochAmounts.issuedAt = block.timestamp.toUint64();
        epochId[poolId][scId_][depositAssetId].issue = nowIssueEpochId;

        emit IssueShares(
            poolId,
            scId_,
            depositAssetId,
            nowIssueEpochId,
            pricePoolPerShare,
            epochAmounts.pricePoolPerAsset.isNotZero()
                ? PricingLib.priceAssetPerShare(epochAmounts.pricePoolPerShare, epochAmounts.pricePoolPerAsset)
                : d18(0),
            issuedShareAmount
        );

        bytes memory callback =
            RequestCallbackMessageLib.IssuedShares(issuedShareAmount, pricePoolPerShare.raw()).serialize();
        hub.requestCallback{value: msgValue()}(poolId, scId_, depositAssetId, callback, extraGasLimit, refund);
    }

    /// @inheritdoc IBatchRequestManager
    function revokeShares(
        PoolId poolId,
        ShareClassId scId_,
        AssetId payoutAssetId,
        uint32 nowRevokeEpochId,
        D18 pricePoolPerShare,
        uint128 extraGasLimit,
        address refund
    ) external payable isManager(poolId) {
        (uint128 payoutAssetAmount, uint128 revokedShareAmount) =
            _revokeShares(poolId, scId_, payoutAssetId, nowRevokeEpochId, pricePoolPerShare);

        bytes memory callback = RequestCallbackMessageLib.RevokedShares(
                payoutAssetAmount, revokedShareAmount, pricePoolPerShare.raw()
            ).serialize();
        hub.requestCallback{value: msgValue()}(poolId, scId_, payoutAssetId, callback, extraGasLimit, refund);
    }

    function _revokeShares(
        PoolId poolId,
        ShareClassId scId_,
        AssetId payoutAssetId,
        uint32 nowRevokeEpochId,
        D18 pricePoolPerShare
    ) internal returns (uint128 payoutAssetAmount, uint128 revokedShareAmount) {
        require(nowRevokeEpochId <= epochId[poolId][scId_][payoutAssetId].redeem, EpochNotFound());
        require(
            nowRevokeEpochId == nowRevokeEpoch(poolId, scId_, payoutAssetId),
            EpochNotInSequence(nowRevokeEpochId, nowRevokeEpoch(poolId, scId_, payoutAssetId))
        );

        EpochRedeemAmounts storage epochAmounts = epochRedeemAmounts[poolId][scId_][payoutAssetId][nowRevokeEpochId];
        epochAmounts.pricePoolPerShare = pricePoolPerShare;

        // NOTE: shares and pool currency have the same decimals - no conversion needed!
        uint128 payoutPoolAmount = pricePoolPerShare.mulUint128(epochAmounts.approvedShareAmount, MathLib.Rounding.Down);

        payoutAssetAmount = epochAmounts.pricePoolPerAsset.isNotZero()
            ? PricingLib.shareToAssetAmount(
                epochAmounts.approvedShareAmount,
                hubRegistry.decimals(poolId),
                hubRegistry.decimals(payoutAssetId),
                epochAmounts.pricePoolPerShare,
                epochAmounts.pricePoolPerAsset,
                MathLib.Rounding.Down
            )
            : 0;
        revokedShareAmount = epochAmounts.approvedShareAmount;

        epochAmounts.payoutAssetAmount = payoutAssetAmount;
        epochAmounts.revokedAt = block.timestamp.toUint64();
        epochId[poolId][scId_][payoutAssetId].revoke = nowRevokeEpochId;

        emit RevokeShares(
            poolId,
            scId_,
            payoutAssetId,
            nowRevokeEpochId,
            pricePoolPerShare,
            epochAmounts.pricePoolPerAsset.isNotZero()
                ? PricingLib.priceAssetPerShare(epochAmounts.pricePoolPerShare, epochAmounts.pricePoolPerAsset)
                : d18(0),
            epochAmounts.approvedShareAmount,
            payoutAssetAmount,
            payoutPoolAmount
        );
    }

    /// @inheritdoc IBatchRequestManager
    function forceCancelDepositRequest(
        PoolId poolId,
        ShareClassId scId_,
        bytes32 investor,
        AssetId depositAssetId,
        address refund
    ) external payable isManager(poolId) {
        require(allowForceDepositCancel[poolId][scId_][depositAssetId][investor], CancellationInitializationRequired());

        uint128 cancellingAmount = depositRequest[poolId][scId_][depositAssetId][investor].pending;
        uint128 cancelledAssetAmount =
            _updatePending(poolId, scId_, cancellingAmount, false, investor, depositAssetId, RequestType.Deposit);

        // Cancellation might have been queued such that it will be executed in the future during claiming
        if (cancelledAssetAmount > 0) {
            bytes memory callback =
                RequestCallbackMessageLib.FulfilledDepositRequest(investor, 0, 0, cancelledAssetAmount).serialize();
            hub.requestCallback{value: msgValue()}(poolId, scId_, depositAssetId, callback, 0, refund);
        }
    }

    /// @inheritdoc IBatchRequestManager
    function forceCancelRedeemRequest(
        PoolId poolId,
        ShareClassId scId_,
        bytes32 investor,
        AssetId payoutAssetId,
        address refund
    ) external payable isManager(poolId) {
        require(allowForceRedeemCancel[poolId][scId_][payoutAssetId][investor], CancellationInitializationRequired());

        uint128 cancellingAmount = redeemRequest[poolId][scId_][payoutAssetId][investor].pending;
        uint128 cancelledShareAmount =
            _updatePending(poolId, scId_, cancellingAmount, false, investor, payoutAssetId, RequestType.Redeem);

        // Cancellation might have been queued such that it will be executed in the future during claiming
        if (cancelledShareAmount > 0) {
            bytes memory callback =
                RequestCallbackMessageLib.FulfilledRedeemRequest(investor, 0, 0, cancelledShareAmount).serialize();
            hub.requestCallback{value: msgValue()}(poolId, scId_, payoutAssetId, callback, 0, refund);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Claiming methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubRequestManagerNotifications
    function notifyDeposit(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint32 maxClaims,
        address refund
    ) external payable protected {
        uint128 totalPayoutShareAmount;
        uint128 totalPaymentAssetAmount;
        uint128 cancelledAssetAmount;

        for (uint32 i = 0; i < maxClaims; i++) {
            (uint128 payoutShareAmount, uint128 paymentAssetAmount, uint128 cancelled, bool canClaimAgain) =
                _claimDeposit(poolId, scId, investor, assetId);

            totalPayoutShareAmount += payoutShareAmount;
            totalPaymentAssetAmount += paymentAssetAmount;

            // Should be written at most once with non-zero amount iff the last claimable epoch was processed and
            // the user had a pending cancellation
            // NOTE: Purposely delaying corresponding message dispatch after deposit fulfillment message
            if (cancelled > 0) {
                cancelledAssetAmount = cancelled;
            }

            if (!canClaimAgain) {
                break;
            }
        }

        if (totalPaymentAssetAmount > 0 || cancelledAssetAmount > 0) {
            hub.requestCallback{
                value: msgValue()
            }(
                poolId,
                scId,
                assetId,
                RequestCallbackMessageLib.FulfilledDepositRequest(
                        investor, totalPaymentAssetAmount, totalPayoutShareAmount, cancelledAssetAmount
                    ).serialize(),
                0,
                refund
            );
        }
    }

    function _claimDeposit(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId depositAssetId)
        internal
        returns (
            uint128 payoutShareAmount,
            uint128 paymentAssetAmount,
            uint128 cancelledAssetAmount,
            bool canClaimAgain
        )
    {
        UserOrder storage userOrder = depositRequest[poolId][scId_][depositAssetId][investor];
        require(userOrder.pending > 0, NoOrderFound());
        require(userOrder.lastUpdate <= epochId[poolId][scId_][depositAssetId].issue, IssuanceRequired());
        canClaimAgain = userOrder.lastUpdate < epochId[poolId][scId_][depositAssetId].issue;
        EpochInvestAmounts storage epochAmounts =
            epochInvestAmounts[poolId][scId_][depositAssetId][userOrder.lastUpdate];

        paymentAssetAmount = epochAmounts.approvedAssetAmount == 0
            ? 0
            : userOrder.pending.mulDiv(epochAmounts.approvedAssetAmount, epochAmounts.pendingAssetAmount).toUint128();

        // NOTE: Due to precision loss, the sum of claimable user amounts is leq than the amount of minted share class
        // tokens corresponding to the approved share amount (instead of equality). I.e., it is possible for an epoch to
        // have an excess of a share class tokens which cannot be claimed by anyone.
        if (paymentAssetAmount > 0) {
            payoutShareAmount = epochAmounts.pricePoolPerShare.isNotZero()
                ? PricingLib.assetToShareAmount(
                    paymentAssetAmount,
                    hubRegistry.decimals(depositAssetId),
                    hubRegistry.decimals(poolId),
                    epochAmounts.pricePoolPerAsset,
                    epochAmounts.pricePoolPerShare,
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
            userOrder.lastUpdate = nowDepositEpoch(poolId, scId_, depositAssetId);
            canClaimAgain = false;
        } else {
            userOrder.lastUpdate += 1;
        }

        // If user claimed up to latest approval epoch, move queued to pending
        if (userOrder.lastUpdate == nowDepositEpoch(poolId, scId_, depositAssetId)) {
            cancelledAssetAmount =
                _postClaimUpdateQueued(poolId, scId_, investor, depositAssetId, userOrder, RequestType.Deposit);
        }
    }

    /// @inheritdoc IHubRequestManagerNotifications
    function notifyRedeem(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint32 maxClaims,
        address refund
    ) external payable protected {
        uint128 totalPayoutAssetAmount;
        uint128 totalPaymentShareAmount;
        uint128 cancelledShareAmount;

        for (uint32 i = 0; i < maxClaims; i++) {
            (uint128 payoutAssetAmount, uint128 paymentShareAmount, uint128 cancelled, bool canClaimAgain) =
                _claimRedeem(poolId, scId, investor, assetId);

            totalPayoutAssetAmount += payoutAssetAmount;
            totalPaymentShareAmount += paymentShareAmount;

            // Should be written at most once with non-zero amount iff the last claimable epoch was processed and
            // the user had a pending cancellation
            // NOTE: Purposely delaying corresponding message dispatch after redemption fulfillment message
            if (cancelled > 0) {
                cancelledShareAmount = cancelled;
            }

            if (!canClaimAgain) {
                break;
            }
        }
        if (totalPaymentShareAmount > 0 || cancelledShareAmount > 0) {
            hub.requestCallback{
                value: msgValue()
            }(
                poolId,
                scId,
                assetId,
                RequestCallbackMessageLib.FulfilledRedeemRequest(
                        investor, totalPayoutAssetAmount, totalPaymentShareAmount, cancelledShareAmount
                    ).serialize(),
                0,
                refund
            );
        }
    }

    function _claimRedeem(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId payoutAssetId)
        internal
        returns (
            uint128 payoutAssetAmount,
            uint128 paymentShareAmount,
            uint128 cancelledShareAmount,
            bool canClaimAgain
        )
    {
        UserOrder storage userOrder = redeemRequest[poolId][scId_][payoutAssetId][investor];
        require(userOrder.pending > 0, NoOrderFound());
        require(userOrder.lastUpdate <= epochId[poolId][scId_][payoutAssetId].revoke, RevocationRequired());
        canClaimAgain = userOrder.lastUpdate < epochId[poolId][scId_][payoutAssetId].revoke;

        EpochRedeemAmounts storage epochAmounts = epochRedeemAmounts[poolId][scId_][payoutAssetId][userOrder.lastUpdate];

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
                    epochAmounts.pricePoolPerShare,
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
            userOrder.lastUpdate = nowRedeemEpoch(poolId, scId_, payoutAssetId);
            canClaimAgain = false;
        } else {
            userOrder.lastUpdate += 1;
        }

        if (userOrder.lastUpdate == nowRedeemEpoch(poolId, scId_, payoutAssetId)) {
            cancelledShareAmount =
                _postClaimUpdateQueued(poolId, scId_, investor, payoutAssetId, userOrder, RequestType.Redeem);
        }
    }

    //----------------------------------------------------------------------------------------------
    // ERC-165
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IBatchRequestManager).interfaceId
            || interfaceId == type(IHubRequestManager).interfaceId
            || interfaceId == type(IHubRequestManagerNotifications).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBatchRequestManager
    function nowDepositEpoch(PoolId poolId, ShareClassId scId_, AssetId depositAssetId) public view returns (uint32) {
        return epochId[poolId][scId_][depositAssetId].deposit + 1;
    }

    /// @inheritdoc IBatchRequestManager
    function nowIssueEpoch(PoolId poolId, ShareClassId scId_, AssetId depositAssetId) public view returns (uint32) {
        return epochId[poolId][scId_][depositAssetId].issue + 1;
    }

    /// @inheritdoc IBatchRequestManager
    function nowRedeemEpoch(PoolId poolId, ShareClassId scId_, AssetId depositAssetId) public view returns (uint32) {
        return epochId[poolId][scId_][depositAssetId].redeem + 1;
    }

    /// @inheritdoc IBatchRequestManager
    function nowRevokeEpoch(PoolId poolId, ShareClassId scId_, AssetId depositAssetId) public view returns (uint32) {
        return epochId[poolId][scId_][depositAssetId].revoke + 1;
    }

    /// @inheritdoc IBatchRequestManager
    function maxDepositClaims(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId depositAssetId)
        public
        view
        returns (uint32)
    {
        return _maxClaims(
            depositRequest[poolId][scId_][depositAssetId][investor], epochId[poolId][scId_][depositAssetId].issue
        );
    }

    /// @inheritdoc IBatchRequestManager
    function maxRedeemClaims(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId payoutAssetId)
        public
        view
        returns (uint32)
    {
        return _maxClaims(
            redeemRequest[poolId][scId_][payoutAssetId][investor], epochId[poolId][scId_][payoutAssetId].revoke
        );
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
            ? queuedDepositRequest[poolId][scId_][assetId][investor]
            : queuedRedeemRequest[poolId][scId_][assetId][investor];

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
            ? depositRequest[poolId][scId_][assetId][investor]
            : redeemRequest[poolId][scId_][assetId][investor];
        QueuedOrder storage queued = requestType == RequestType.Deposit
            ? queuedDepositRequest[poolId][scId_][assetId][investor]
            : queuedRedeemRequest[poolId][scId_][assetId][investor];

        // We must only update either queued or pending
        if (_updateQueued(poolId, scId_, amount, isIncrement, investor, assetId, userOrder, queued, requestType)) {
            return 0;
        }

        cancelledAmount = isIncrement ? 0 : amount;
        // NOTE: If we decrease the pending, we decrease usually by the full amount
        //       We keep subtraction of amount over setting to zero on purpose to not limit future higher level logic
        userOrder.pending = isIncrement ? userOrder.pending + amount : userOrder.pending - amount;

        userOrder.lastUpdate = requestType == RequestType.Deposit
            ? nowDepositEpoch(poolId, scId_, assetId)
            : nowRedeemEpoch(poolId, scId_, assetId);

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
        uint32 currentEpoch = requestType == RequestType.Deposit
            ? nowDepositEpoch(poolId, scId_, assetId)
            : nowRedeemEpoch(poolId, scId_, assetId);

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
            uint128 pendingTotal = pendingDeposit[poolId][scId_][assetId];
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
            uint128 pendingTotal = pendingRedeem[poolId][scId_][assetId];

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
        uint128 pendingTotal = pendingDeposit[poolId][scId_][assetId];
        pendingTotal = isIncrement ? pendingTotal + amount : pendingTotal - amount;
        pendingDeposit[poolId][scId_][assetId] = pendingTotal;

        emit UpdateDepositRequest(
            poolId,
            scId_,
            assetId,
            nowDepositEpoch(poolId, scId_, assetId),
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
        uint128 pendingTotal = pendingRedeem[poolId][scId_][assetId];
        pendingTotal = isIncrement ? pendingTotal + amount : pendingTotal - amount;
        pendingRedeem[poolId][scId_][assetId] = pendingTotal;

        emit UpdateRedeemRequest(
            poolId,
            scId_,
            assetId,
            nowRedeemEpoch(poolId, scId_, assetId),
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
