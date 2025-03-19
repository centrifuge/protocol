// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {Auth} from "src/misc/Auth.sol";
import {D18} from "src/misc/types/D18.sol";
import {ITransientValuation} from "src/misc/interfaces/ITransientValuation.sol";

import {MessageCategory, MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";
import {JournalEntry, Meta} from "src/common/types/JournalEntry.sol";

import {IMessageProcessor} from "src/vaults/interfaces/IMessageProcessor.sol";
import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {IInvestmentManager} from "src/vaults/interfaces/IInvestmentManager.sol";
import {IBalanceSheetManager} from "src/vaults/interfaces/IBalanceSheetManager.sol";

contract MessageProcessor is Auth, IMessageProcessor, IMessageHandler {
    using MessageLib for *;
    using BytesLib for bytes;
    using CastLib for *;

    IMessageSender public immutable gateway;
    IPoolManager public immutable poolManager;
    IInvestmentManager public immutable investmentManager;
    IBalanceSheetManager public immutable balanceSheetManager;
    IRoot public immutable root;
    IGasService public immutable gasService;

    constructor(
        IMessageSender sender_,
        IPoolManager poolManager_,
        IInvestmentManager investmentManager_,
        IBalanceSheetManager balanceSheetManager_,
        IRoot root_,
        IGasService gasService_,
        address deployer
    ) Auth(deployer) {
        gateway = sender_;
        poolManager = poolManager_;
        investmentManager = investmentManager_;
        balanceSheetManager = balanceSheetManager_;
        root = root_;
        gasService = gasService_;
    }

    /// @inheritdoc IMessageProcessor
    function sendTransferShares(uint32 chainId, uint64 poolId, bytes16 scId, bytes32 recipient, uint128 amount)
        external
        auth
    {
        gateway.send(
            chainId,
            MessageLib.TransferShares({poolId: poolId, scId: scId, recipient: recipient, amount: amount}).serialize()
        );
    }

    /// @inheritdoc IMessageProcessor
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

    /// @inheritdoc IMessageProcessor
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

    /// @inheritdoc IMessageProcessor
    function sendCancelDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external auth {
        gateway.send(
            uint32(poolId >> 32),
            MessageLib.CancelDepositRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId})
                .serialize()
        );
    }

    /// @inheritdoc IMessageProcessor
    function sendCancelRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external auth {
        gateway.send(
            uint32(poolId >> 32),
            MessageLib.CancelRedeemRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId}).serialize(
            )
        );
    }

    /// @inheritdoc IMessageProcessor
    function sendIncreaseHolding(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        uint256 timestamp,
        JournalEntry[] calldata debits,
        JournalEntry[] calldata credits
    ) external auth {
        MessageLib.UpdateHolding memory data = MessageLib.UpdateHolding({
            poolId: poolId,
            scId: scId,
            assetId: assetId,
            who: provider.toBytes32(),
            amount: amount,
            pricePerUnit: pricePerUnit,
            timestamp: timestamp,
            isIncrease: true,
            asAllowance: false, // @dev never relevant for the CP side
            debits: debits,
            credits: credits
        });

        gateway.send(uint32(poolId >> 32), data.serialize());
    }

    /// @inheritdoc IMessageProcessor
    function sendDecreaseHolding(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        uint256 timestamp,
        JournalEntry[] calldata debits,
        JournalEntry[] calldata credits
    ) external auth {
        MessageLib.UpdateHolding memory data = MessageLib.UpdateHolding({
            poolId: poolId,
            scId: scId,
            assetId: assetId,
            who: receiver.toBytes32(),
            amount: amount,
            pricePerUnit: pricePerUnit,
            timestamp: timestamp,
            isIncrease: false,
            asAllowance: false, // @dev never relevant for the CP side
            debits: debits,
            credits: credits
        });

        gateway.send(uint32(poolId >> 32), data.serialize());
    }

    /// @notice Creates and send the message
    function sendIssueShares(uint64 poolId, bytes16 scId, address receiver, uint128 shares, uint256 timestamp)
        external
    {
        gateway.send(
            uint32(poolId >> 32),
            MessageLib.UpdateShares({
                poolId: poolId,
                scId: scId,
                who: receiver.toBytes32(),
                shares: shares,
                timestamp: timestamp,
                isIssuance: true
            }).serialize()
        );
    }

    /// @notice Creates and send the message
    function sendRevokeShares(uint64 poolId, bytes16 scId, address provider, uint128 shares, uint256 timestamp)
        external
    {
        gateway.send(
            uint32(poolId >> 32),
            MessageLib.UpdateShares({
                poolId: poolId,
                scId: scId,
                who: provider.toBytes32(),
                shares: shares,
                timestamp: timestamp,
                isIssuance: false
            }).serialize()
        );
    }

    /// @notice Creates and send the message
    function sendJournalEntry(
        uint64 poolId,
        bytes16 scId,
        JournalEntry[] calldata debits,
        JournalEntry[] calldata credits
    ) external {
        gateway.send(
            uint32(poolId >> 32),
            MessageLib.UpdateJournal({poolId: poolId, scId: scId, debits: debits, credits: credits}).serialize()
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
                    address(bytes20(m.target)), address(bytes20(m.token)), address(bytes20(m.to)), m.amount
                );
            } else {
                revert InvalidMessage(uint8(kind));
            }
        } else if (cat == MessageCategory.Gas) {
            if (kind == MessageType.UpdateGasPrice) {
                MessageLib.UpdateGasPrice memory m = message.deserializeUpdateGasPrice();
                gasService.updateGasPrice(m.price, m.timestamp);
            } else {
                revert InvalidMessage(uint8(kind));
            }
        } else if (cat == MessageCategory.Pool) {
            if (kind == MessageType.RegisterAsset) {
                // TODO: This must be removed
                poolManager.addAsset(message.toUint128(1), message.toAddress(17));
            } else if (kind == MessageType.NotifyPool) {
                poolManager.addPool(MessageLib.deserializeNotifyPool(message).poolId);
            } else if (kind == MessageType.NotifyShareClass) {
                MessageLib.NotifyShareClass memory m = MessageLib.deserializeNotifyShareClass(message);
                poolManager.addTranche(
                    m.poolId, m.scId, m.name, m.symbol.toString(), m.decimals, m.salt, address(bytes20(m.hook))
                );
            } else if (kind == MessageType.AllowAsset) {
                MessageLib.AllowAsset memory m = MessageLib.deserializeAllowAsset(message);
                poolManager.allowAsset(m.poolId, /* m.scId, */ m.assetId); // TODO: use scId
            } else if (kind == MessageType.DisallowAsset) {
                MessageLib.DisallowAsset memory m = MessageLib.deserializeDisallowAsset(message);
                poolManager.disallowAsset(m.poolId, /* m.scId, */ m.assetId); // TODO: use scId
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
        } else if (cat == MessageCategory.BalanceSheet) {
            if (kind == MessageType.UpdateHolding) {
                MessageLib.UpdateHolding memory m = message.deserializeUpdateHolding();

                Meta memory meta = Meta({timestamp: m.timestamp, debits: m.debits, credits: m.credits});
                if (m.isIncrease) {
                    balanceSheetManager.deposit(
                        // TODO: Fix `tokenId`
                        m.poolId,
                        m.scId,
                        poolManager.idToAsset(m.assetId),
                        0,
                        address(bytes20(m.who)),
                        m.amount,
                        m.pricePerUnit,
                        meta
                    );
                } else {
                    balanceSheetManager.withdraw(
                        // TODO: Fix `tokenId`
                        m.poolId,
                        m.scId,
                        poolManager.idToAsset(m.assetId),
                        0,
                        address(bytes20(m.who)),
                        m.amount,
                        m.pricePerUnit,
                        m.asAllowance,
                        meta
                    );
                }
            } else {
                revert InvalidMessage(uint8(kind));
            }
        } else {
            revert InvalidMessage(uint8(kind));
        }
    }
}
