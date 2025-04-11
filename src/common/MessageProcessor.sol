// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {Auth} from "src/misc/Auth.sol";
import {D18} from "src/misc/types/D18.sol";
import {ITransientValuation} from "src/misc/interfaces/ITransientValuation.sol";
import {IRecoverable} from "src/misc/interfaces/IRecoverable.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IMessageProcessor} from "src/common/interfaces/IMessageProcessor.sol";
import {IMessageProperties} from "src/common/interfaces/IMessageProperties.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";
import {JournalEntry, Meta} from "src/common/libraries/JournalEntryLib.sol";
import {
    IGatewayHandler,
    IPoolManagerGatewayHandler,
    IBalanceSheetGatewayHandler,
    IHubGatewayHandler,
    IInvestmentManagerGatewayHandler
} from "src/common/interfaces/IGatewayHandlers.sol";
import {IVaultMessageSender, IPoolMessageSender} from "src/common/interfaces/IGatewaySenders.sol";

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

    /// @inheritdoc IMessageHandler
    function handle(uint16, bytes calldata message) external auth {
        MessageType kind = message.messageType();

        if (kind == MessageType.InitiateMessageRecovery) {
            MessageLib.InitiateMessageRecovery memory m = message.deserializeInitiateMessageRecovery();
            gateway.initiateMessageRecovery(m.centrifugeId, IAdapter(m.adapter.toAddress()), m.hash);
        } else if (kind == MessageType.DisputeMessageRecovery) {
            MessageLib.DisputeMessageRecovery memory m = message.deserializeDisputeMessageRecovery();
            gateway.disputeMessageRecovery(m.centrifugeId, IAdapter(m.adapter.toAddress()), m.hash);
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
            poolManager.addPool(MessageLib.deserializeNotifyPool(message).poolId);
        } else if (kind == MessageType.NotifyShareClass) {
            MessageLib.NotifyShareClass memory m = MessageLib.deserializeNotifyShareClass(message);
            poolManager.addShareClass(
                m.poolId, m.scId, m.name, m.symbol.toString(), m.decimals, m.salt, m.hook.toAddress()
            );
        } else if (kind == MessageType.NotifyPricePoolPerShare) {
            MessageLib.NotifyPricePoolPerShare memory m = MessageLib.deserializeNotifyPricePoolPerShare(message);
            poolManager.updatePricePoolPerShare(m.poolId, m.scId, m.price, m.timestamp);
        } else if (kind == MessageType.NotifyPricePoolPerAsset) {
            MessageLib.NotifyPricePoolPerAsset memory m = MessageLib.deserializeNotifyPricePoolPerAsset(message);
            poolManager.updatePricePoolPerAsset(m.poolId, m.scId, m.assetId, m.price, m.timestamp);
        } else if (kind == MessageType.UpdateShareClassMetadata) {
            MessageLib.UpdateShareClassMetadata memory m = MessageLib.deserializeUpdateShareClassMetadata(message);
            poolManager.updateShareMetadata(m.poolId, m.scId, m.name, m.symbol.toString());
        } else if (kind == MessageType.UpdateShareClassHook) {
            MessageLib.UpdateShareClassHook memory m = MessageLib.deserializeUpdateShareClassHook(message);
            poolManager.updateShareHook(m.poolId, m.scId, m.hook.toAddress());
        } else if (kind == MessageType.TransferShares) {
            MessageLib.TransferShares memory m = MessageLib.deserializeTransferShares(message);
            poolManager.handleTransferShares(m.poolId, m.scId, m.receiver.toAddress(), m.amount);
        } else if (kind == MessageType.UpdateRestriction) {
            MessageLib.UpdateRestriction memory m = MessageLib.deserializeUpdateRestriction(message);
            poolManager.updateRestriction(m.poolId, m.scId, m.payload);
        } else if (kind == MessageType.UpdateContract) {
            MessageLib.UpdateContract memory m = MessageLib.deserializeUpdateContract(message);
            poolManager.updateContract(m.poolId, m.scId, m.target.toAddress(), m.payload);
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
                m.poolId, m.scId, m.investor.toAddress(), m.assetId, m.assetAmount, m.shareAmount
            );
        } else if (kind == MessageType.FulfilledRedeemRequest) {
            MessageLib.FulfilledRedeemRequest memory m = message.deserializeFulfilledRedeemRequest();
            investmentManager.fulfillRedeemRequest(
                m.poolId, m.scId, m.investor.toAddress(), m.assetId, m.assetAmount, m.shareAmount
            );
        } else if (kind == MessageType.FulfilledCancelDepositRequest) {
            MessageLib.FulfilledCancelDepositRequest memory m = message.deserializeFulfilledCancelDepositRequest();
            investmentManager.fulfillCancelDepositRequest(
                m.poolId, m.scId, m.investor.toAddress(), m.assetId, m.cancelledAmount, m.cancelledAmount
            );
        } else if (kind == MessageType.FulfilledCancelRedeemRequest) {
            MessageLib.FulfilledCancelRedeemRequest memory m = message.deserializeFulfilledCancelRedeemRequest();
            investmentManager.fulfillCancelRedeemRequest(
                m.poolId, m.scId, m.investor.toAddress(), m.assetId, m.cancelledShares
            );
        } else if (kind == MessageType.TriggerRedeemRequest) {
            MessageLib.TriggerRedeemRequest memory m = message.deserializeTriggerRedeemRequest();
            investmentManager.triggerRedeemRequest(m.poolId, m.scId, m.investor.toAddress(), m.assetId, m.shares);
        } else if (kind == MessageType.TriggerUpdateHoldingAmount) {
            MessageLib.TriggerUpdateHoldingAmount memory m = message.deserializeTriggerUpdateHoldingAmount();

            Meta memory meta = Meta({debits: m.debits, credits: m.credits});
            if (m.isIncrease) {
                balanceSheet.triggerDeposit(
                    PoolId.wrap(m.poolId),
                    ShareClassId.wrap(m.scId),
                    AssetId.wrap(m.assetId),
                    m.who.toAddress(),
                    m.amount,
                    D18.wrap(m.pricePerUnit),
                    meta
                );
            } else {
                balanceSheet.triggerWithdraw(
                    PoolId.wrap(m.poolId),
                    ShareClassId.wrap(m.scId),
                    AssetId.wrap(m.assetId),
                    m.who.toAddress(),
                    m.amount,
                    D18.wrap(m.pricePerUnit),
                    meta
                );
            }
        } else if (kind == MessageType.TriggerUpdateShares) {
            MessageLib.TriggerUpdateShares memory m = message.deserializeTriggerUpdateShares();
            if (m.isIssuance) {
                balanceSheet.triggerIssueShares(
                    PoolId.wrap(m.poolId),
                    ShareClassId.wrap(m.scId),
                    m.who.toAddress(),
                    D18.wrap(m.pricePerShare),
                    m.shares
                );
            } else {
                balanceSheet.triggerRevokeShares(
                    PoolId.wrap(m.poolId),
                    ShareClassId.wrap(m.scId),
                    m.who.toAddress(),
                    D18.wrap(m.pricePerShare),
                    m.shares
                );
            }
        } else if (kind == MessageType.UpdateHoldingAmount) {
            MessageLib.UpdateHoldingAmount memory m = message.deserializeUpdateHoldingAmount();
            hub.updateHoldingAmount(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                AssetId.wrap(m.assetId),
                m.amount,
                D18.wrap(m.pricePerUnit),
                m.isIncrease,
                m.debits,
                m.credits
            );
        } else if (kind == MessageType.UpdateHoldingValue) {
            MessageLib.UpdateHoldingValue memory m = message.deserializeUpdateHoldingValue();
            hub.updateHoldingValue(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), AssetId.wrap(m.assetId), D18.wrap(m.pricePerUnit)
            );
        } else if (kind == MessageType.UpdateJournal) {
            MessageLib.UpdateJournal memory m = message.deserializeUpdateJournal();
            hub.updateJournal(PoolId.wrap(m.poolId), m.debits, m.credits);
        } else if (kind == MessageType.UpdateShares) {
            MessageLib.UpdateShares memory m = message.deserializeUpdateShares();
            if (m.isIssuance) {
                hub.increaseShareIssuance(
                    PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), D18.wrap(m.pricePerShare), m.shares
                );
            } else {
                hub.decreaseShareIssuance(
                    PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), D18.wrap(m.pricePerShare), m.shares
                );
            }
        } else if (kind == MessageType.ApprovedDeposits) {
            MessageLib.ApprovedDeposits memory m = message.deserializeApprovedDeposits();
            balanceSheet.approvedDeposits(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), AssetId.wrap(m.assetId), m.assetAmount
            );
        } else if (kind == MessageType.RevokedShares) {
            MessageLib.RevokedShares memory m = message.deserializeRevokedShares();
            balanceSheet.revokedShares(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), AssetId.wrap(m.assetId), m.assetAmount
            );
        } else {
            revert InvalidMessage(uint8(kind));
        }
    }

    /// @inheritdoc IMessageProperties
    function isMessageRecovery(bytes calldata message) external pure returns (bool) {
        uint8 code = message.messageCode();
        return code == uint8(MessageType.InitiateMessageRecovery) || code == uint8(MessageType.DisputeMessageRecovery);
    }

    /// @inheritdoc IMessageProperties
    function messageLength(bytes calldata message) external pure returns (uint16) {
        return message.messageLength();
    }

    /// @inheritdoc IMessageProperties
    function messagePoolId(bytes calldata message) external pure returns (PoolId) {
        return message.messagePoolId();
    }

    /// @inheritdoc IMessageProperties
    function messageProofHash(bytes calldata message) external pure returns (bytes32) {
        return (message.messageCode() == uint8(MessageType.MessageProof))
            ? message.deserializeMessageProof().hash
            : bytes32(0);
    }

    /// @inheritdoc IMessageProperties
    function createMessageProof(bytes calldata message) external pure returns (bytes memory) {
        return MessageLib.MessageProof({hash: keccak256(message)}).serialize();
    }
}
