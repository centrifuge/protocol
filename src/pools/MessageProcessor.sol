// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {Auth} from "src/misc/Auth.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";

import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {IMessageProcessor} from "src/pools/interfaces/IMessageProcessor.sol";
import {IPoolManagerHandler} from "src/pools/interfaces/IPoolManager.sol";

contract MessageProcessor is Auth, IMessageProcessor {
    using MessageLib for *;
    using BytesLib for bytes;
    using CastLib for *;

    IPoolManagerHandler public immutable manager;
    IMessageSender public immutable sender;

    constructor(IMessageSender sender_, IPoolManagerHandler manager_, address deployer) Auth(deployer) {
        sender = sender_;
        manager = manager_;
    }

    /// @inheritdoc IMessageProcessor
    function sendNotifyPool(uint32 chainId, PoolId poolId) external auth {
        // In case we want to optimize for the same network:
        //if chainId == uint32(block.chainId) {
        //    cv.poolManager.notifyPool(poolId);
        //}
        //else {
        sender.send(chainId, MessageLib.NotifyPool({poolId: poolId.raw()}).serialize());
        //}
    }

    /// @inheritdoc IMessageProcessor
    function sendNotifyShareClass(
        uint32 chainId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        bytes32 hook
    ) external auth {
        sender.send(
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

    /// @inheritdoc IMessageProcessor
    function sendNotifyAllowedAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool isAllowed) external auth {
        bytes memory message = isAllowed
            ? MessageLib.AllowAsset({poolId: poolId.raw(), scId: scId.raw(), assetId: assetId.raw()}).serialize()
            : MessageLib.DisallowAsset({poolId: poolId.raw(), scId: scId.raw(), assetId: assetId.raw()}).serialize();

        sender.send(assetId.chainId(), message);
    }

    /// @inheritdoc IMessageProcessor
    function sendFulfilledDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 assetAmount,
        uint128 shareAmount
    ) external auth {
        sender.send(
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

    /// @inheritdoc IMessageProcessor
    function sendFulfilledRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 assetAmount,
        uint128 shareAmount
    ) external auth {
        sender.send(
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

    /// @inheritdoc IMessageProcessor
    function sendFulfilledCancelDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledAmount
    ) external auth {
        sender.send(
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

    /// @inheritdoc IMessageProcessor
    function sendFulfilledCancelRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledShares
    ) external auth {
        sender.send(
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

    /// @inheritdoc IMessageHandler
    function handle(bytes memory message) external auth {
        MessageType kind = message.messageType();

        if (kind == MessageType.RegisterAsset) {
            MessageLib.RegisterAsset memory m = message.deserializeRegisterAsset();
            manager.registerAsset(AssetId.wrap(m.assetId), m.name, m.symbol.toString(), m.decimals);
        } else if (kind == MessageType.DepositRequest) {
            MessageLib.DepositRequest memory m = message.deserializeDepositRequest();
            manager.depositRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId), m.amount
            );
        } else if (kind == MessageType.RedeemRequest) {
            MessageLib.RedeemRequest memory m = message.deserializeRedeemRequest();
            manager.redeemRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId), m.amount
            );
        } else if (kind == MessageType.CancelDepositRequest) {
            MessageLib.CancelDepositRequest memory m = message.deserializeCancelDepositRequest();
            manager.cancelDepositRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId)
            );
        } else if (kind == MessageType.CancelRedeemRequest) {
            MessageLib.CancelRedeemRequest memory m = message.deserializeCancelRedeemRequest();
            manager.cancelRedeemRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId)
            );
        } else {
            revert InvalidMessage(uint8(kind));
        }
    }
}
