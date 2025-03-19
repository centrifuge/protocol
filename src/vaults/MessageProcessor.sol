// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {Auth} from "src/misc/Auth.sol";

import {MessageCategory, MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";
import {
    IInvestmentManagerGatewayHandler, IPoolManagerGatewayHandler
} from "src/common/interfaces/IGatewayHandlers.sol";
import {IVaultMessageSender} from "src/common/interfaces/IGatewaySenders.sol";

contract MessageProcessor is Auth, IVaultMessageSender, IMessageHandler {
    using MessageLib for *;
    using BytesLib for bytes;
    using CastLib for *;

    IMessageSender public immutable gateway;
    IPoolManagerGatewayHandler public immutable poolManager;
    IInvestmentManagerGatewayHandler public immutable investmentManager;
    IRoot public immutable root;
    IGasService public immutable gasService;

    constructor(
        IMessageSender sender_,
        IPoolManagerGatewayHandler poolManager_,
        IInvestmentManagerGatewayHandler investmentManager_,
        IRoot root_,
        IGasService gasService_,
        address deployer
    ) Auth(deployer) {
        gateway = sender_;
        poolManager = poolManager_;
        investmentManager = investmentManager_;
        root = root_;
        gasService = gasService_;
    }

    /// @inheritdoc IVaultMessageSender
    function sendTransferShares(uint32 chainId, uint64 poolId, bytes16 scId, bytes32 recipient, uint128 amount)
        external
        auth
    {
        gateway.send(
            chainId,
            MessageLib.TransferShares({poolId: poolId, scId: scId, recipient: recipient, amount: amount}).serialize()
        );
    }

    /// @inheritdoc IVaultMessageSender
    function sendDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external
        auth
    {
        gateway.send(
            uint32(poolId >> 32),
            MessageLib.DepositRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId, amount: amount})
                .serialize()
        );
    }

    /// @inheritdoc IVaultMessageSender
    function sendRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external
        auth
    {
        gateway.send(
            uint32(poolId >> 32),
            MessageLib.RedeemRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId, amount: amount})
                .serialize()
        );
    }

    /// @inheritdoc IVaultMessageSender
    function sendCancelDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external auth {
        gateway.send(
            uint32(poolId >> 32),
            MessageLib.CancelDepositRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId})
                .serialize()
        );
    }

    /// @inheritdoc IVaultMessageSender
    function sendCancelRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external auth {
        gateway.send(
            uint32(poolId >> 32),
            MessageLib.CancelRedeemRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId}).serialize(
            )
        );
    }

    /// @inheritdoc IVaultMessageSender
    function sendRegisterAsset(
        uint32 chainId,
        uint128 assetId,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) external auth {
        gateway.send(
            chainId,
            MessageLib.RegisterAsset({assetId: assetId, name: name, symbol: symbol.toBytes32(), decimals: decimals})
                .serialize()
        );
    }

    /// @inheritdoc IMessageHandler
    function handle(uint32, /* chainId */ bytes memory message) external auth {
        MessageCategory cat = message.messageCode().category();
        MessageType kind = message.messageType();

        if (cat == MessageCategory.Root) {
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
            } else {
                revert InvalidMessage(uint8(kind));
            }
        } else if (cat == MessageCategory.Pool) {
            if (kind == MessageType.NotifyPool) {
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
            } else {
                revert InvalidMessage(uint8(kind));
            }
        } else if (cat == MessageCategory.Investment) {
            if (kind == MessageType.FulfilledDepositRequest) {
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
                investmentManager.triggerRedeemRequest(
                    m.poolId, m.scId, address(bytes20(m.investor)), m.assetId, m.shares
                );
            } else {
                revert InvalidMessage(uint8(kind));
            }
        } else {
            revert InvalidMessage(uint8(kind));
        }
    }
}
