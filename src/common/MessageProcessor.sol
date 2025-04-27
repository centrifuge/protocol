// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {Auth} from "src/misc/Auth.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IRecoverable} from "src/misc/interfaces/IRecoverable.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IMessageProcessor} from "src/common/interfaces/IMessageProcessor.sol";
import {IMessageProperties} from "src/common/interfaces/IMessageProperties.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {
    IGatewayHandler,
    IPoolManagerGatewayHandler,
    IBalanceSheetGatewayHandler,
    IHubGatewayHandler,
    IInvestmentManagerGatewayHandler
} from "src/common/interfaces/IGatewayHandlers.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ITokenRecoverer} from "src/common/interfaces/ITokenRecoverer.sol";

contract MessageProcessor is Auth, IMessageProcessor {
    using CastLib for *;
    using MessageLib for *;
    using BytesLib for bytes;

    IRoot public immutable root;
    ITokenRecoverer public immutable tokenRecoverer;

    IGatewayHandler public gateway;
    IHubGatewayHandler public hub;
    IPoolManagerGatewayHandler public poolManager;
    IInvestmentManagerGatewayHandler public investmentManager;
    IBalanceSheetGatewayHandler public balanceSheet;

    constructor(IRoot root_, ITokenRecoverer tokenRecoverer_, address deployer) Auth(deployer) {
        root = root_;
        tokenRecoverer = tokenRecoverer_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageProcessor
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGatewayHandler(data);
        else if (what == "hub") hub = IHubGatewayHandler(data);
        else if (what == "poolManager") poolManager = IPoolManagerGatewayHandler(data);
        else if (what == "investmentManager") investmentManager = IInvestmentManagerGatewayHandler(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheetGatewayHandler(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Handlers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageHandler
    function handle(uint16, bytes calldata message) external auth {
        MessageType kind = message.messageType();

        if (kind == MessageType.InitiateRecovery) {
            MessageLib.InitiateRecovery memory m = message.deserializeInitiateRecovery();
            gateway.initiateRecovery(m.centrifugeId, IAdapter(m.adapter.toAddress()), m.hash);
        } else if (kind == MessageType.DisputeRecovery) {
            MessageLib.DisputeRecovery memory m = message.deserializeDisputeRecovery();
            gateway.disputeRecovery(m.centrifugeId, IAdapter(m.adapter.toAddress()), m.hash);
        } else if (kind == MessageType.ScheduleUpgrade) {
            MessageLib.ScheduleUpgrade memory m = message.deserializeScheduleUpgrade();
            root.scheduleRely(m.target.toAddress());
        } else if (kind == MessageType.CancelUpgrade) {
            MessageLib.CancelUpgrade memory m = message.deserializeCancelUpgrade();
            root.cancelRely(m.target.toAddress());
        } else if (kind == MessageType.RecoverTokens) {
            MessageLib.RecoverTokens memory m = message.deserializeRecoverTokens();
            tokenRecoverer.recoverTokens(
                IRecoverable(m.target.toAddress()), m.token.toAddress(), m.tokenId, m.to.toAddress(), m.amount
            );
        } else if (kind == MessageType.RegisterAsset) {
            MessageLib.RegisterAsset memory m = message.deserializeRegisterAsset();
            hub.registerAsset(AssetId.wrap(m.assetId), m.decimals);
        } else if (kind == MessageType.NotifyPool) {
            poolManager.addPool(PoolId.wrap(MessageLib.deserializeNotifyPool(message).poolId));
        } else if (kind == MessageType.NotifyShareClass) {
            MessageLib.NotifyShareClass memory m = MessageLib.deserializeNotifyShareClass(message);
            poolManager.addShareClass(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                m.name,
                m.symbol.toString(),
                m.decimals,
                m.salt,
                m.hook.toAddress()
            );
        } else if (kind == MessageType.NotifyPricePoolPerShare) {
            MessageLib.NotifyPricePoolPerShare memory m = MessageLib.deserializeNotifyPricePoolPerShare(message);
            poolManager.updatePricePoolPerShare(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.price, m.timestamp);
        } else if (kind == MessageType.NotifyPricePoolPerAsset) {
            MessageLib.NotifyPricePoolPerAsset memory m = MessageLib.deserializeNotifyPricePoolPerAsset(message);
            poolManager.updatePricePoolPerAsset(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), AssetId.wrap(m.assetId), m.price, m.timestamp
            );
        } else if (kind == MessageType.NotifyShareMetadata) {
            MessageLib.NotifyShareMetadata memory m = MessageLib.deserializeNotifyShareMetadata(message);
            poolManager.updateShareMetadata(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.name, m.symbol.toString()
            );
        } else if (kind == MessageType.UpdateShareHook) {
            MessageLib.UpdateShareHook memory m = MessageLib.deserializeUpdateShareHook(message);
            poolManager.updateShareHook(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.hook.toAddress());
        } else if (kind == MessageType.TransferShares) {
            MessageLib.TransferShares memory m = MessageLib.deserializeTransferShares(message);
            poolManager.handleTransferShares(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.receiver.toAddress(), m.amount
            );
        } else if (kind == MessageType.UpdateRestriction) {
            MessageLib.UpdateRestriction memory m = MessageLib.deserializeUpdateRestriction(message);
            poolManager.updateRestriction(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.payload);
        } else if (kind == MessageType.UpdateContract) {
            MessageLib.UpdateContract memory m = MessageLib.deserializeUpdateContract(message);
            poolManager.updateContract(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.target.toAddress(), m.payload
            );
        } else if (kind == MessageType.DepositRequest) {
            MessageLib.DepositRequest memory m = message.deserializeDepositRequest();
            hub.depositRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId), m.amount
            );
        } else if (kind == MessageType.RedeemRequest) {
            MessageLib.RedeemRequest memory m = message.deserializeRedeemRequest();
            hub.redeemRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId), m.amount
            );
        } else if (kind == MessageType.CancelDepositRequest) {
            MessageLib.CancelDepositRequest memory m = message.deserializeCancelDepositRequest();
            hub.cancelDepositRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId)
            );
        } else if (kind == MessageType.CancelRedeemRequest) {
            MessageLib.CancelRedeemRequest memory m = message.deserializeCancelRedeemRequest();
            hub.cancelRedeemRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId)
            );
        } else if (kind == MessageType.FulfilledDepositRequest) {
            MessageLib.FulfilledDepositRequest memory m = message.deserializeFulfilledDepositRequest();
            investmentManager.fulfillDepositRequest(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                m.investor.toAddress(),
                AssetId.wrap(m.assetId),
                m.assetAmount,
                m.shareAmount
            );
        } else if (kind == MessageType.FulfilledRedeemRequest) {
            MessageLib.FulfilledRedeemRequest memory m = message.deserializeFulfilledRedeemRequest();
            investmentManager.fulfillRedeemRequest(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                m.investor.toAddress(),
                AssetId.wrap(m.assetId),
                m.assetAmount,
                m.shareAmount
            );
        } else if (kind == MessageType.FulfilledCancelDepositRequest) {
            MessageLib.FulfilledCancelDepositRequest memory m = message.deserializeFulfilledCancelDepositRequest();
            investmentManager.fulfillCancelDepositRequest(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                m.investor.toAddress(),
                AssetId.wrap(m.assetId),
                m.cancelledAmount,
                m.cancelledAmount
            );
        } else if (kind == MessageType.FulfilledCancelRedeemRequest) {
            MessageLib.FulfilledCancelRedeemRequest memory m = message.deserializeFulfilledCancelRedeemRequest();
            investmentManager.fulfillCancelRedeemRequest(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                m.investor.toAddress(),
                AssetId.wrap(m.assetId),
                m.cancelledShares
            );
        } else if (kind == MessageType.TriggerIssueShares) {
            MessageLib.TriggerIssueShares memory m = message.deserializeTriggerIssueShares();
            balanceSheet.triggerIssueShares(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.who.toAddress(), m.shares
            );
        } else if (kind == MessageType.UpdateHoldingAmount) {
            MessageLib.UpdateHoldingAmount memory m = message.deserializeUpdateHoldingAmount();
            hub.updateHoldingAmount(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                AssetId.wrap(m.assetId),
                m.amount,
                D18.wrap(m.pricePerUnit),
                m.isIncrease
            );
        } else if (kind == MessageType.UpdateShares) {
            MessageLib.UpdateShares memory m = message.deserializeUpdateShares();
            if (m.isIssuance) {
                hub.increaseShareIssuance(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.shares);
            } else {
                hub.decreaseShareIssuance(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.shares);
            }
        } else if (kind == MessageType.ApprovedDeposits) {
            MessageLib.ApprovedDeposits memory m = message.deserializeApprovedDeposits();
            investmentManager.approvedDeposits(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                AssetId.wrap(m.assetId),
                m.assetAmount,
                D18.wrap(m.pricePoolPerAsset)
            );
        } else if (kind == MessageType.IssuedShares) {
            MessageLib.IssuedShares memory m = message.deserializeIssuedShares();
            investmentManager.issuedShares(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.shareAmount, D18.wrap(m.pricePoolPerShare)
            );
        } else if (kind == MessageType.RevokedShares) {
            MessageLib.RevokedShares memory m = message.deserializeRevokedShares();
            investmentManager.revokedShares(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                AssetId.wrap(m.assetId),
                m.assetAmount,
                m.shareAmount,
                D18.wrap(m.pricePoolPerShare)
            );
        } else if (kind == MessageType.TriggerSubmitQueuedShares) {
            MessageLib.TriggerSubmitQueuedShares memory m = message.deserializeTriggerSubmitQueuedShares();
            balanceSheet.submitQueuedShares(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId));
        } else if (kind == MessageType.TriggerSubmitQueuedAssets) {
            MessageLib.TriggerSubmitQueuedAssets memory m = message.deserializeTriggerSubmitQueuedAssets();
            balanceSheet.submitQueuedAssets(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), AssetId.wrap(m.assetId));
        } else if (kind == MessageType.SetQueue) {
            MessageLib.SetQueue memory m = message.deserializeSetQueue();
            balanceSheet.setQueue(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.enabled);
        } else {
            revert InvalidMessage(uint8(kind));
        }
    }

    /// @inheritdoc IMessageProperties
    function isMessageRecovery(bytes calldata message) external pure returns (bool) {
        uint8 code = message.messageCode();
        return code == uint8(MessageType.InitiateRecovery) || code == uint8(MessageType.DisputeRecovery);
    }

    /// @inheritdoc IMessageProperties
    function messageLength(bytes calldata message) external pure returns (uint16) {
        return message.messageLength();
    }

    /// @inheritdoc IMessageProperties
    function messagePoolId(bytes calldata message) external pure returns (PoolId) {
        return message.messagePoolId();
    }
}
