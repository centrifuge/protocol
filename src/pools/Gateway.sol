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
    using MessageLib for bytes;
    using BytesLib for bytes;
    using CastLib for string;
    using CastLib for bytes;
    using CastLib for bytes32;

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
        _send(chainId, MessageLib.serialize(MessageLib.NotifyPool({poolId: poolId.raw()})));
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
            MessageLib.serialize(
                MessageLib.NotifyShareClass({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    name: name,
                    symbol: symbol.toBytes32(),
                    decimals: decimals,
                    hook: hook
                })
            )
        );
    }

    function sendNotifyAllowedAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool isAllowed) external auth {
        bytes memory message = isAllowed
            ? MessageLib.serialize(MessageLib.AllowAsset({poolId: poolId.raw(), scId: scId.raw(), assetId: assetId.raw()}))
            : MessageLib.serialize(
                MessageLib.DisallowAsset({poolId: poolId.raw(), scId: scId.raw(), assetId: assetId.raw()})
            );

        _send(assetId.chainId(), message);
    }

    function sendFulfilledDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 shareAmount,
        uint128 assetAmount
    ) external auth {
        _send(
            assetId.chainId(),
            MessageLib.serialize(
                MessageLib.FulfilledDepositRequest({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    investor: investor,
                    assetId: assetId.raw(),
                    shareAmount: shareAmount,
                    assetAmount: assetAmount
                })
            )
        );
    }

    function sendFulfilledRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 shareAmount,
        uint128 assetAmount
    ) external auth {
        _send(
            assetId.chainId(),
            MessageLib.serialize(
                MessageLib.FulfilledRedeemRequest({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    investor: investor,
                    assetId: assetId.raw(),
                    shareAmount: shareAmount,
                    assetAmount: assetAmount
                })
            )
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
            MessageLib.serialize(
                MessageLib.FulfilledCancelDepositRequest({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    investor: investor,
                    assetId: assetId.raw(),
                    cancelledAmount: cancelledAmount
                })
            )
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
            MessageLib.serialize(
                MessageLib.FulfilledCancelRedeemRequest({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    investor: investor,
                    assetId: assetId.raw(),
                    cancelledShares: cancelledShares
                })
            )
        );
    }

    function handle(bytes calldata message) external auth {
        MessageType kind = message.messageType();

        if (kind == MessageType.RegisterAsset) {
            MessageLib.RegisterAsset memory t = message.deserializeRegisterAsset();
            handler.handleRegisterAsset(AssetId.wrap(t.assetId), t.name, t.symbol.toString(), t.decimals);
        } else if (kind == MessageType.DepositRequest) {
            MessageLib.DepositRequest memory t = message.deserializeDepositRequest();
            handler.handleDepositRequest(
                PoolId.wrap(t.poolId), ShareClassId.wrap(t.scId), t.investor, AssetId.wrap(t.assetId), t.amount
            );
        } else if (kind == MessageType.RedeemRequest) {
            MessageLib.RedeemRequest memory t = message.deserializeRedeemRequest();
            handler.handleRedeemRequest(
                PoolId.wrap(t.poolId), ShareClassId.wrap(t.scId), t.investor, AssetId.wrap(t.assetId), t.amount
            );
        } else if (kind == MessageType.CancelDepositRequest) {
            MessageLib.CancelDepositRequest memory t = message.deserializeCancelDepositRequest();
            handler.handleCancelDepositRequest(
                PoolId.wrap(t.poolId), ShareClassId.wrap(t.scId), t.investor, AssetId.wrap(t.assetId)
            );
        } else if (kind == MessageType.CancelRedeemRequest) {
            MessageLib.CancelRedeemRequest memory t = message.deserializeCancelRedeemRequest();
            handler.handleCancelRedeemRequest(
                PoolId.wrap(t.poolId), ShareClassId.wrap(t.scId), t.investor, AssetId.wrap(t.assetId)
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
