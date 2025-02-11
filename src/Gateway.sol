// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ShareClassId} from "src/types/ShareClassId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {PoolId} from "src/types/PoolId.sol";

import {IGateway} from "src/interfaces/IGateway.sol";
import {IMessageHandler} from "src/interfaces/IMessageHandler.sol";
import {IAdapter} from "src/interfaces/IAdapter.sol";
import {IPoolManagerHandler} from "src/interfaces/IPoolManager.sol";

import {CastLib} from "src/libraries/CastLib.sol";
import {BytesLib} from "src/libraries/BytesLib.sol";
import {MessageType, MessageLib} from "src/libraries/MessageLib.sol";

import {Auth} from "src/Auth.sol";

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
        _send(chainId, abi.encodePacked(MessageType.AddPool, poolId.raw()));
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
            abi.encodePacked(
                MessageType.AddTranche,
                poolId.raw(),
                scId.raw(),
                name.stringToBytes128(),
                symbol.toBytes32(),
                decimals,
                hook
            )
        );
    }

    function sendNotifyAllowedAsset(PoolId poolId, ShareClassId, /*scId*/ AssetId assetId, bool isAllowed)
        external
        auth
    {
        bytes memory message = isAllowed
            ? abi.encodePacked(MessageType.AllowAsset, poolId.raw(), assetId.raw())
            : abi.encodePacked(MessageType.DisallowAsset, poolId.raw(), assetId.raw());

        _send(assetId.chainId(), message);
    }

    function sendFulfilledDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 shares,
        uint128 investedAmount
    ) external auth {
        _send(
            assetId.chainId(),
            abi.encodePacked(
                MessageType.FulfilledDepositRequest,
                poolId.raw(),
                scId.raw(),
                investor,
                assetId.raw(),
                shares,
                investedAmount
            )
        );
    }

    function sendFulfilledRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 shares,
        uint128 investedAmount
    ) external auth {
        _send(
            assetId.chainId(),
            abi.encodePacked(
                MessageType.FulfilledRedeemRequest,
                poolId.raw(),
                scId.raw(),
                investor,
                assetId.raw(),
                shares,
                investedAmount
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
            abi.encodePacked(
                MessageType.FulfilledCancelDepositRequest,
                poolId.raw(),
                scId.raw(),
                investor,
                assetId.raw(),
                cancelledAmount,
                cancelledAmount
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
            abi.encodePacked(
                MessageType.FulfilledCancelRedeemRequest,
                poolId.raw(),
                scId.raw(),
                investor,
                assetId.raw(),
                cancelledShares
            )
        );
    }

    function sendUnlockAssets(AssetId assetId, bytes32 receiver, uint128 assetAmount) external auth {
        _send(assetId.chainId(), abi.encodePacked(MessageType.TransferAssets, assetId.raw(), receiver, assetAmount));
    }

    function handle(bytes calldata message) external auth {
        MessageType kind = message.messageType();

        if (kind == MessageType.RegisterAsset) {
            handler.handleRegisterAsset(
                AssetId.wrap(message.toUint128(1)),
                message.slice(17, 128).bytes128ToString(),
                message.toBytes32(145).toString(),
                message.toUint8(177)
            );
        } else if (kind == MessageType.TransferAssets) {
            handler.handleLockedTokens(
                AssetId.wrap(message.toUint128(1)), address(bytes20(message.toBytes32(16))), message.toUint128(49)
            );
        } else if (kind == MessageType.DepositRequest) {
            handler.handleRequestDeposit(
                PoolId.wrap(message.toUint64(1)),
                ShareClassId.wrap(message.toBytes16(9)),
                message.toBytes32(25),
                AssetId.wrap(message.toUint128(57)),
                message.toUint128(73)
            );
        } else if (kind == MessageType.RedeemRequest) {
            handler.handleRequestRedeem(
                PoolId.wrap(message.toUint64(1)),
                ShareClassId.wrap(message.toBytes16(9)),
                message.toBytes32(25),
                AssetId.wrap(message.toUint128(57)),
                message.toUint128(73)
            );
        } else if (kind == MessageType.CancelDepositRequest) {
            handler.handleCancelDepositRequest(
                PoolId.wrap(message.toUint64(1)),
                ShareClassId.wrap(message.toBytes16(9)),
                message.toBytes32(25),
                AssetId.wrap(message.toUint128(57))
            );
        } else if (kind == MessageType.CancelRedeemRequest) {
            handler.handleCancelRedeemRequest(
                PoolId.wrap(message.toUint64(1)),
                ShareClassId.wrap(message.toBytes16(9)),
                message.toBytes32(25),
                AssetId.wrap(message.toUint128(57))
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
