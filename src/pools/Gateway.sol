// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {Auth} from "src/misc/Auth.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";

import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {IGateway} from "src/pools/interfaces/IGateway.sol";
import {IMessageHandler} from "src/pools/interfaces/IMessageHandler.sol";
import {IAdapter} from "src/pools/interfaces/IAdapter.sol";
import {IPoolManagerHandler} from "src/pools/interfaces/IPoolManager.sol";

contract Gateway is Auth, IGateway, IMessageHandler {
    using MessageLib for *;
    using BytesLib for bytes;
    using CastLib for *;

    IAdapter public adapter; // TODO: several adapters
    IPoolManagerHandler public handler;

    constructor(IAdapter adapter_, IPoolManagerHandler handler_, address deployer) Auth(deployer) {
        adapter = adapter_;
        handler = handler_;
    }

    /// @inheritdoc IGateway
    function file(bytes32 what, address data) external auth {
        if (what == "adapter") adapter = IAdapter(data);
        else if (what == "handler") handler = IPoolManagerHandler(data);
        else revert FileUnrecognizedWhat();

        emit File(what, data);
    }

    function sendNotifyPool(uint32 chainId, PoolId poolId) external auth {
        // TODO: call directly to CV.poolManager if same chain (apply in all send*() methods)
        _send(chainId, MessageLib.NotifyPool({poolId: poolId.raw()}).serialize());
    }

    function sendNotifyShareClass(
        uint32 chainId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 hook
    ) external auth {
        _send(
            chainId,
            MessageLib.NotifyShareClass({
                poolId: poolId.raw(),
                scId: scId.raw(),
                name: name,
                symbol: symbol.toBytes32(),
                decimals: decimals,
                hook: hook
            }).serialize()
        );
    }

    function sendNotifyAllowedAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool isAllowed) external auth {
        bytes memory message = isAllowed
            ? MessageLib.AllowAsset({poolId: poolId.raw(), scId: scId.raw(), assetId: assetId.raw()}).serialize()
            : MessageLib.DisallowAsset({poolId: poolId.raw(), scId: scId.raw(), assetId: assetId.raw()}).serialize();

        _send(assetId.chainId(), message);
    }

    function sendFulfilledDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 assetAmount,
        uint128 shareAmount
    ) external auth {
        _send(
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

    function sendFulfilledRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 assetAmount,
        uint128 shareAmount
    ) external auth {
        _send(
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

    function sendFulfilledCancelDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledAmount
    ) external auth {
        _send(
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

    function sendFulfilledCancelRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledShares
    ) external auth {
        _send(
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

    function handle(bytes calldata message) external auth {
        MessageType kind = message.messageType();

        if (kind == MessageType.RegisterAsset) {
            MessageLib.RegisterAsset memory m = message.deserializeRegisterAsset();
            handler.registerAsset(AssetId.wrap(m.assetId), m.name, m.symbol.toString(), m.decimals);
        } else if (kind == MessageType.DepositRequest) {
            MessageLib.DepositRequest memory m = message.deserializeDepositRequest();
            handler.depositRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId), m.amount
            );
        } else if (kind == MessageType.RedeemRequest) {
            MessageLib.RedeemRequest memory m = message.deserializeRedeemRequest();
            handler.redeemRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId), m.amount
            );
        } else if (kind == MessageType.CancelDepositRequest) {
            MessageLib.CancelDepositRequest memory m = message.deserializeCancelDepositRequest();
            handler.cancelDepositRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId)
            );
        } else if (kind == MessageType.CancelRedeemRequest) {
            MessageLib.CancelRedeemRequest memory m = message.deserializeCancelRedeemRequest();
            handler.cancelRedeemRequest(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.investor, AssetId.wrap(m.assetId)
            );
        } else {
            revert InvalidMessage(uint8(kind));
        }
    }

    function _send(uint32 chainId, bytes memory message) private {
        // TODO: generate proofs and send message through handlers
        adapter.send(chainId, message);
    }
}
