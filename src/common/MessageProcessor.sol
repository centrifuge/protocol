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

interface IMessageProcessor is IVaultMessageSender, IPoolMessageSender, IMessageHandler {
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

    IMessageSender public immutable gateway;
    IRoot public immutable root;
    IGasService public immutable gasService;

    IPoolRouterGatewayHandler public poolRouter;
    IPoolManagerGatewayHandler public poolManager;
    IInvestmentManagerGatewayHandler public investmentManager;
    IBalanceSheetManagerGatewayHandler public balanceSheetManager;

    uint16 public centrifugeChainId;

    constructor(
        uint16 centrifugeChainId_,
        IMessageSender gateway_,
        IRoot root_,
        IGasService gasService_,
        address deployer
    ) Auth(deployer) {
        centrifugeChainId = centrifugeChainId_;
        gateway = gateway_;
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

    /// @inheritdoc IPoolMessageSender
    function sendNotifyPool(uint16 chainId, PoolId poolId) external auth {
        // In case we want to optimize for the same network:
        //if chainId == centrifugeChainId {
        //    cv.poolManager.notifyPool(poolId);
        //}
        //else {
        gateway.send(chainId, MessageLib.NotifyPool({poolId: poolId.raw()}).serialize());
        //}
    }

    /// @inheritdoc IPoolMessageSender
    function sendNotifyShareClass(
        uint16 chainId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        bytes32 hook
    ) external auth {
        gateway.send(
            chainId,
            MessageLib.NotifyShareClass({
                poolId: poolId.raw(),
                scId: scId.raw(),
                name: name,
                symbol: symbol.toBytes32(),
                decimals: decimals,
                salt: salt,
                hook: hook
            }).serialize()
        );
    }

    /// @inheritdoc IPoolMessageSender
    function sendFulfilledDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 assetAmount,
        uint128 shareAmount
    ) external auth {
        gateway.send(
            assetId.chainId(),
            MessageLib.FulfilledDepositRequest({
                poolId: poolId.raw(),
                scId: scId.raw(),
                investor: investor,
                assetId: assetId.raw(),
                assetAmount: assetAmount,
                shareAmount: shareAmount
            }).serialize()
        );
    }

    /// @inheritdoc IPoolMessageSender
    function sendFulfilledRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 assetAmount,
        uint128 shareAmount
    ) external auth {
        gateway.send(
            assetId.chainId(),
            MessageLib.FulfilledRedeemRequest({
                poolId: poolId.raw(),
                scId: scId.raw(),
                investor: investor,
                assetId: assetId.raw(),
                assetAmount: assetAmount,
                shareAmount: shareAmount
            }).serialize()
        );
    }

    /// @inheritdoc IPoolMessageSender
    function sendFulfilledCancelDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledAmount
    ) external auth {
        gateway.send(
            assetId.chainId(),
            MessageLib.FulfilledCancelDepositRequest({
                poolId: poolId.raw(),
                scId: scId.raw(),
                investor: investor,
                assetId: assetId.raw(),
                cancelledAmount: cancelledAmount
            }).serialize()
        );
    }

    /// @inheritdoc IPoolMessageSender
    function sendFulfilledCancelRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledShares
    ) external auth {
        gateway.send(
            assetId.chainId(),
            MessageLib.FulfilledCancelRedeemRequest({
                poolId: poolId.raw(),
                scId: scId.raw(),
                investor: investor,
                assetId: assetId.raw(),
                cancelledShares: cancelledShares
            }).serialize()
        );
    }

    /// @inheritdoc IPoolMessageSender
    function sendUpdateContract(
        uint16 chainId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 target,
        bytes calldata payload
    ) external auth {
        gateway.send(
            chainId,
            MessageLib.UpdateContract({poolId: poolId.raw(), scId: scId.raw(), target: target, payload: payload})
                .serialize()
        );
    }

    /// @inheritdoc IVaultMessageSender
    function sendTransferShares(uint16 chainId, uint64 poolId, bytes16 scId, bytes32 recipient, uint128 amount)
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
            PoolId.wrap(poolId).chainId(),
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
            PoolId.wrap(poolId).chainId(),
            MessageLib.RedeemRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId, amount: amount})
                .serialize()
        );
    }

    /// @inheritdoc IVaultMessageSender
    function sendCancelDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external auth {
        gateway.send(
            PoolId.wrap(poolId).chainId(),
            MessageLib.CancelDepositRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId})
                .serialize()
        );
    }

    /// @inheritdoc IVaultMessageSender
    function sendCancelRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external auth {
        gateway.send(
            PoolId.wrap(poolId).chainId(),
            MessageLib.CancelRedeemRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId}).serialize(
            )
        );
    }

    /// @inheritdoc IVaultMessageSender
    function sendIncreaseHolding(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        uint256 timestamp,
        JournalEntry[] calldata debits,
        JournalEntry[] calldata credits
    ) external auth {
        MessageLib.UpdateHolding memory data = MessageLib.UpdateHolding({
            poolId: poolId.raw(),
            scId: scId.raw(),
            assetId: assetId.raw(),
            who: provider.toBytes32(),
            amount: amount,
            pricePerUnit: pricePerUnit,
            timestamp: timestamp,
            isIncrease: true,
            debits: debits,
            credits: credits
        });

        gateway.send(poolId.chainId(), data.serialize());
    }

    /// @inheritdoc IVaultMessageSender
    function sendDecreaseHolding(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        uint256 timestamp,
        JournalEntry[] calldata debits,
        JournalEntry[] calldata credits
    ) external auth {
        MessageLib.UpdateHolding memory data = MessageLib.UpdateHolding({
            poolId: poolId.raw(),
            scId: scId.raw(),
            assetId: assetId.raw(),
            who: receiver.toBytes32(),
            amount: amount,
            pricePerUnit: pricePerUnit,
            timestamp: timestamp,
            isIncrease: false,
            debits: debits,
            credits: credits
        });

        gateway.send(poolId.chainId(), data.serialize());
    }

    /// @inheritdoc IVaultMessageSender
    function sendUpdateHoldingValue(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        D18 pricePerUnit,
        uint256 timestamp
    ) external auth {
        JournalEntry[] memory debits = new JournalEntry[](0);
        JournalEntry[] memory credits = new JournalEntry[](0);

        MessageLib.UpdateHolding memory data = MessageLib.UpdateHolding({
            poolId: poolId.raw(),
            scId: scId.raw(),
            assetId: assetId.raw(),
            who: bytes32(0),
            amount: 0,
            pricePerUnit: pricePerUnit,
            timestamp: timestamp,
            isIncrease: false,
            debits: debits,
            credits: credits
        });

        gateway.send(poolId.chainId(), data.serialize());
    }

    /// @inheritdoc IVaultMessageSender
    function sendIssueShares(
        PoolId poolId,
        ShareClassId scId,
        address receiver,
        D18 pricePerShare,
        uint128 shares,
        uint256 timestamp
    ) external {
        gateway.send(
            poolId.chainId(),
            MessageLib.UpdateShares({
                poolId: poolId.raw(),
                scId: scId.raw(),
                who: receiver.toBytes32(),
                pricePerShare: pricePerShare,
                shares: shares,
                timestamp: timestamp,
                isIssuance: true
            }).serialize()
        );
    }

    /// @inheritdoc IVaultMessageSender
    function sendRevokeShares(
        PoolId poolId,
        ShareClassId scId,
        address provider,
        D18 pricePerShare,
        uint128 shares,
        uint256 timestamp
    ) external {
        gateway.send(
            poolId.chainId(),
            MessageLib.UpdateShares({
                poolId: poolId.raw(),
                scId: scId.raw(),
                who: provider.toBytes32(),
                pricePerShare: pricePerShare,
                shares: shares,
                timestamp: timestamp,
                isIssuance: false
            }).serialize()
        );
    }

    /// @inheritdoc IVaultMessageSender
    function sendJournalEntry(
        PoolId poolId,
        ShareClassId scId,
        JournalEntry[] calldata debits,
        JournalEntry[] calldata credits
    ) external {
        gateway.send(
            poolId.chainId(),
            MessageLib.UpdateJournal({poolId: poolId.raw(), scId: scId.raw(), debits: debits, credits: credits})
                .serialize()
        );
    }

    /// @inheritdoc IVaultMessageSender
    function sendRegisterAsset(
        uint16 chainId,
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
    function handle(uint16, /* chainId */ bytes memory message) external auth {
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
            if (kind == MessageType.RegisterAsset) {
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
            } else {
                revert InvalidMessage(uint8(kind));
            }
        } else if (cat == MessageCategory.Investment) {
            if (kind == MessageType.DepositRequest) {
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
                investmentManager.triggerRedeemRequest(
                    m.poolId, m.scId, address(bytes20(m.investor)), m.assetId, m.shares
                );
            } else {
                revert InvalidMessage(uint8(kind));
            }
        } else if (cat == MessageCategory.BalanceSheet) {
            if (kind == MessageType.TriggerUpdateHolding) {
                MessageLib.TriggerUpdateHolding memory m = message.deserializeTriggerUpdateHolding();

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
                        PoolId.wrap(m.poolId),
                        ShareClassId.wrap(m.scId),
                        address(bytes20(m.who)),
                        m.pricePerShare,
                        m.shares
                    );
                }
            } else if (kind == MessageType.UpdateHolding) {
                MessageLib.UpdateHolding memory m = message.deserializeUpdateHolding();

                if (m.amount == 0) {
                    poolRouter.updateHoldingValue(
                        PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), AssetId.wrap(m.assetId), m.pricePerUnit
                    );
                } else {
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
                }
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
        } else {
            revert InvalidMessage(uint8(kind));
        }
    }
}
