// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {Auth} from "src/misc/Auth.sol";
import {D18} from "src/misc/types/D18.sol";
import {ITransientValuation} from "src/misc/interfaces/ITransientValuation.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";
import {JournalEntry, Meta} from "src/common/types/JournalEntry.sol";
import {
    IInvestmentManagerGatewayHandler,
    IPoolManagerGatewayHandler,
    IPoolRouterGatewayHandler,
    IBalanceSheetManagerGatewayHandler
} from "src/common/interfaces/IGatewayHandlers.sol";
import {IVaultMessageSender, IPoolMessageSender} from "src/common/interfaces/IGatewaySenders.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";

interface IMessageProcessor is IMessageHandler {
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 indexed what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'poolRegistry' string value.
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;
}

contract MessageProcessor is Auth, IMessageProcessor {
    using MessageLib for *;
    using BytesLib for bytes;
    using CastLib for *;

    IRoot public immutable root;
    IGasService public immutable gasService;

    IPoolRouterGatewayHandler public poolRouter;
    IPoolManagerGatewayHandler public poolManager;
    IInvestmentManagerGatewayHandler public investmentManager;
    IBalanceSheetManagerGatewayHandler public balanceSheetManager;

    constructor(IRoot root_, IGasService gasService_, address deployer) Auth(deployer) {
        root = root_;
        gasService = gasService_;
    }

    /// @inheritdoc IMessageProcessor
    function file(bytes32 what, address data) external auth {
        if (what == "poolRouter") poolRouter = IPoolRouterGatewayHandler(data);
        else if (what == "poolManager") poolManager = IPoolManagerGatewayHandler(data);
        else if (what == "investmentManager") investmentManager = IInvestmentManagerGatewayHandler(data);
        else if (what == "balanceSheetManager") balanceSheetManager = IBalanceSheetManagerGatewayHandler(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    /// @inheritdoc IMessageHandler
    function handle(uint16, bytes calldata message) external auth {
        MessageType kind = message.messageType();

        if (kind == MessageType.ScheduleUpgrade) {
            MessageLib.ScheduleUpgrade memory m = message.deserializeScheduleUpgrade();
            root.scheduleRely(address(bytes20(m.target)));
        } else if (kind == MessageType.CancelUpgrade) {
            MessageLib.CancelUpgrade memory m = message.deserializeCancelUpgrade();
            root.cancelRely(address(bytes20(m.target)));
        } else if (kind == MessageType.RecoverTokens) {
            MessageLib.RecoverTokens memory m = message.deserializeRecoverTokens();
            root.recoverTokens(
                address(bytes20(m.target)), address(bytes20(m.token)), m.tokenId, address(bytes20(m.to)), m.amount
            );
        } else if (kind == MessageType.RegisterAsset) {
            MessageLib.RegisterAsset memory m = message.deserializeRegisterAsset();
            poolRouter.registerAsset(AssetId.wrap(m.assetId), m.name, m.symbol.toString(), m.decimals);
        } else if (kind == MessageType.NotifyPool) {
            poolManager.addPool(MessageLib.deserializeNotifyPool(message).poolId);
        } else if (kind == MessageType.NotifyShareClass) {
            MessageLib.NotifyShareClass memory m = MessageLib.deserializeNotifyShareClass(message);
            poolManager.addTranche(
                m.poolId, m.scId, m.name, m.symbol.toString(), m.decimals, m.salt, address(bytes20(m.hook))
            );
        } else if (kind == MessageType.UpdateShareClassPrice) {
            MessageLib.UpdateShareClassPrice memory m = MessageLib.deserializeUpdateShareClassPrice(message);
            poolManager.updateTranchePrice(m.poolId, m.scId, m.assetId, m.price, m.timestamp);
        } else if (kind == MessageType.UpdateShareClassMetadata) {
            MessageLib.UpdateShareClassMetadata memory m = MessageLib.deserializeUpdateShareClassMetadata(message);
            poolManager.updateTrancheMetadata(m.poolId, m.scId, m.name, m.symbol.toString());
        } else if (kind == MessageType.UpdateShareClassHook) {
            MessageLib.UpdateShareClassHook memory m = MessageLib.deserializeUpdateShareClassHook(message);
            poolManager.updateTrancheHook(m.poolId, m.scId, address(bytes20(m.hook)));
        } else if (kind == MessageType.TransferShares) {
            MessageLib.TransferShares memory m = MessageLib.deserializeTransferShares(message);
            poolManager.handleTransferTrancheTokens(m.poolId, m.scId, address(bytes20(m.recipient)), m.amount);
        } else if (kind == MessageType.UpdateRestriction) {
            MessageLib.UpdateRestriction memory m = MessageLib.deserializeUpdateRestriction(message);
            poolManager.updateRestriction(m.poolId, m.scId, m.payload);
        } else if (kind == MessageType.UpdateContract) {
            MessageLib.UpdateContract memory m = MessageLib.deserializeUpdateContract(message);
            poolManager.updateContract(m.poolId, m.scId, address(bytes20(m.target)), m.payload);
        } else if (kind == MessageType.DepositRequest) {
            MessageLib.DepositRequest memory m = message.deserializeDepositRequest();
            poolRouter.depositRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId), m.amount
            );
        } else if (kind == MessageType.RedeemRequest) {
            MessageLib.RedeemRequest memory m = message.deserializeRedeemRequest();
            poolRouter.redeemRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId), m.amount
            );
        } else if (kind == MessageType.CancelDepositRequest) {
            MessageLib.CancelDepositRequest memory m = message.deserializeCancelDepositRequest();
            poolRouter.cancelDepositRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId)
            );
        } else if (kind == MessageType.CancelRedeemRequest) {
            MessageLib.CancelRedeemRequest memory m = message.deserializeCancelRedeemRequest();
            poolRouter.cancelRedeemRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId)
            );
        } else if (kind == MessageType.FulfilledDepositRequest) {
            MessageLib.FulfilledDepositRequest memory m = message.deserializeFulfilledDepositRequest();
            investmentManager.fulfillDepositRequest(
                m.poolId, m.scId, address(bytes20(m.investor)), m.assetId, m.assetAmount, m.shareAmount
            );
        } else if (kind == MessageType.FulfilledRedeemRequest) {
            MessageLib.FulfilledRedeemRequest memory m = message.deserializeFulfilledRedeemRequest();
            investmentManager.fulfillRedeemRequest(
                m.poolId, m.scId, address(bytes20(m.investor)), m.assetId, m.assetAmount, m.shareAmount
            );
        } else if (kind == MessageType.FulfilledCancelDepositRequest) {
            MessageLib.FulfilledCancelDepositRequest memory m = message.deserializeFulfilledCancelDepositRequest();
            investmentManager.fulfillCancelDepositRequest(
                m.poolId, m.scId, address(bytes20(m.investor)), m.assetId, m.cancelledAmount, m.cancelledAmount
            );
        } else if (kind == MessageType.FulfilledCancelRedeemRequest) {
            MessageLib.FulfilledCancelRedeemRequest memory m = message.deserializeFulfilledCancelRedeemRequest();
            investmentManager.fulfillCancelRedeemRequest(
                m.poolId, m.scId, address(bytes20(m.investor)), m.assetId, m.cancelledShares
            );
        } else if (kind == MessageType.TriggerRedeemRequest) {
            MessageLib.TriggerRedeemRequest memory m = message.deserializeTriggerRedeemRequest();
            investmentManager.triggerRedeemRequest(m.poolId, m.scId, address(bytes20(m.investor)), m.assetId, m.shares);
        } else if (kind == MessageType.TriggerUpdateHoldingAmount) {
            MessageLib.TriggerUpdateHoldingAmount memory m = message.deserializeTriggerUpdateHoldingAmount();

            Meta memory meta = Meta({debits: m.debits, credits: m.credits});
            if (m.isIncrease) {
                balanceSheetManager.triggerDeposit(
                    PoolId.wrap(m.poolId),
                    ShareClassId.wrap(m.scId),
                    AssetId.wrap(m.assetId),
                    address(bytes20(m.who)),
                    m.amount,
                    m.pricePerUnit,
                    meta
                );
            } else {
                balanceSheetManager.triggerWithdraw(
                    PoolId.wrap(m.poolId),
                    ShareClassId.wrap(m.scId),
                    AssetId.wrap(m.assetId),
                    address(bytes20(m.who)),
                    m.amount,
                    m.pricePerUnit,
                    m.asAllowance,
                    meta
                );
            }
        } else if (kind == MessageType.TriggerUpdateShares) {
            MessageLib.TriggerUpdateShares memory m = message.deserializeTriggerUpdateShares();
            if (m.isIssuance) {
                balanceSheetManager.triggerIssueShares(
                    PoolId.wrap(m.poolId),
                    ShareClassId.wrap(m.scId),
                    address(bytes20(m.who)),
                    m.pricePerShare,
                    m.shares,
                    m.asAllowance
                );
            } else {
                balanceSheetManager.triggerRevokeShares(
                    PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), address(bytes20(m.who)), m.pricePerShare, m.shares
                );
            }
        } else if (kind == MessageType.UpdateHoldingAmount) {
            MessageLib.UpdateHoldingAmount memory m = message.deserializeUpdateHoldingAmount();
            poolRouter.updateHoldingAmount(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                AssetId.wrap(m.assetId),
                m.amount,
                m.pricePerUnit,
                m.isIncrease,
                m.debits,
                m.credits
            );
        } else if (kind == MessageType.UpdateHoldingValue) {
            MessageLib.UpdateHoldingValue memory m = message.deserializeUpdateHoldingValue();
            poolRouter.updateHoldingValue(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), AssetId.wrap(m.assetId), m.pricePerUnit
            );
        } else if (kind == MessageType.UpdateJournal) {
            MessageLib.UpdateJournal memory m = message.deserializeUpdateJournal();
            poolRouter.updateJournal(PoolId.wrap(m.poolId), m.debits, m.credits);
        } else if (kind == MessageType.UpdateShares) {
            MessageLib.UpdateShares memory m = message.deserializeUpdateShares();
            if (m.isIssuance) {
                poolRouter.increaseShareIssuance(
                    PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.pricePerShare, m.shares
                );
            } else {
                poolRouter.decreaseShareIssuance(
                    PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.pricePerShare, m.shares
                );
            }
        } else {
            revert InvalidMessage(uint8(kind));
        }
    }
}
