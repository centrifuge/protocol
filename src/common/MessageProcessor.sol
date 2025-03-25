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
    IInvestmentManagerGatewayHandler,
    IPoolManagerGatewayHandler,
    IPoolRouterGatewayHandler
} from "src/common/interfaces/IGatewayHandlers.sol";
import {IVaultMessageSender, IPoolMessageSender} from "src/common/interfaces/IGatewaySenders.sol";

import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";

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
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    /// @inheritdoc IPoolMessageSender
    function sendNotifyPool(uint16 chainId, PoolId poolId) external auth {
        if (chainId == centrifugeChainId) {
            poolManager.addPool(poolId.raw());
        } else {
            gateway.send(chainId, MessageLib.NotifyPool({poolId: poolId.raw()}).serialize());
        }
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
        if (chainId == centrifugeChainId) {
            poolManager.addTranche(poolId.raw(), scId.raw(), name, symbol, decimals, salt, address(bytes20(hook)));
        } else {
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
        if (assetId.chainId() == centrifugeChainId) {
            investmentManager.fulfillDepositRequest(
                poolId.raw(), scId.raw(), address(bytes20(investor)), assetId.raw(), assetAmount, shareAmount
            );
        } else {
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
        if (assetId.chainId() == centrifugeChainId) {
            investmentManager.fulfillRedeemRequest(
                poolId.raw(), scId.raw(), address(bytes20(investor)), assetId.raw(), assetAmount, shareAmount
            );
        } else {
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
    }

    /// @inheritdoc IPoolMessageSender
    function sendFulfilledCancelDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledAmount
    ) external auth {
        if (assetId.chainId() == centrifugeChainId) {
            investmentManager.fulfillCancelDepositRequest(
                poolId.raw(), scId.raw(), address(bytes20(investor)), assetId.raw(), cancelledAmount, cancelledAmount
            );
        } else {
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
    }

    /// @inheritdoc IPoolMessageSender
    function sendFulfilledCancelRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledShares
    ) external auth {
        if (assetId.chainId() == centrifugeChainId) {
            investmentManager.fulfillCancelRedeemRequest(
                poolId.raw(), scId.raw(), address(bytes20(investor)), assetId.raw(), cancelledShares
            );
        } else {
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
    }

    /// @inheritdoc IPoolMessageSender
    function sendUpdateContract(
        uint16 chainId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 target,
        bytes calldata payload
    ) external auth {
        if (chainId == centrifugeChainId) {
            poolManager.updateContract(poolId.raw(), scId.raw(), address(bytes20(target)), payload);
        } else {
            gateway.send(
                chainId,
                MessageLib.UpdateContract({poolId: poolId.raw(), scId: scId.raw(), target: target, payload: payload})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendTransferShares(uint16 chainId, uint64 poolId, bytes16 scId, bytes32 recipient, uint128 amount)
        external
        auth
    {
        if (chainId == centrifugeChainId) {
            poolManager.handleTransferTrancheTokens(poolId, scId, address(bytes20(recipient)), amount);
        } else {
            gateway.send(
                chainId,
                MessageLib.TransferShares({poolId: poolId, scId: scId, recipient: recipient, amount: amount}).serialize(
                )
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external
        auth
    {
        if (PoolId.wrap(poolId).chainId() == centrifugeChainId) {
            poolRouter.depositRequest(
                PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId), amount
            );
        } else {
            gateway.send(
                PoolId.wrap(poolId).chainId(),
                MessageLib.DepositRequest({
                    poolId: poolId,
                    scId: scId,
                    investor: investor,
                    assetId: assetId,
                    amount: amount
                }).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external
        auth
    {
        if (PoolId.wrap(poolId).chainId() == centrifugeChainId) {
            poolRouter.redeemRequest(
                PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId), amount
            );
        } else {
            gateway.send(
                PoolId.wrap(poolId).chainId(),
                MessageLib.RedeemRequest({
                    poolId: poolId,
                    scId: scId,
                    investor: investor,
                    assetId: assetId,
                    amount: amount
                }).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendCancelDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external auth {
        if (PoolId.wrap(poolId).chainId() == centrifugeChainId) {
            poolRouter.cancelDepositRequest(
                PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId)
            );
        } else {
            gateway.send(
                PoolId.wrap(poolId).chainId(),
                MessageLib.CancelDepositRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendCancelRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external auth {
        if (PoolId.wrap(poolId).chainId() == centrifugeChainId) {
            poolRouter.cancelRedeemRequest(
                PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId)
            );
        } else {
            gateway.send(
                PoolId.wrap(poolId).chainId(),
                MessageLib.CancelRedeemRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendRegisterAsset(
        uint16 chainId,
        uint128 assetId,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) external auth {
        if (chainId == centrifugeChainId) {
            poolRouter.registerAsset(AssetId.wrap(assetId), name, symbol, decimals);
        } else {
            gateway.send(
                chainId,
                MessageLib.RegisterAsset({assetId: assetId, name: name, symbol: symbol.toBytes32(), decimals: decimals})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IMessageHandler
    function handle(uint16, bytes calldata message) external auth {
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
        } else {
            revert InvalidMessage(uint8(kind));
        }
    }
}
