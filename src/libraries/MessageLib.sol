// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {AssetId, newAssetId} from "src/types/AssetId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";

import {BytesLib} from "src/libraries/BytesLib.sol";
import {CastLib} from "src/libraries/CastLib.sol";

// TODO: update with the latest version of CV.
// By now, only supported messages are added.
enum MessageType {
    Invalid,
    RegisterAsset,
    AddPool,
    AddShareClass,
    AllowAsset,
    DisallowAsset,
    TransferAssets,
    DepositRequest,
    RedeemRequest,
    FulfilledDepositRequest,
    FulfilledRedeemRequest,
    CancelDepositRequest,
    CancelRedeemRequest,
    FulfilledCancelDepositRequest,
    FulfilledCancelRedeemRequest
}

struct RegisterAssetMsg {
    uint128 assetId;
    bytes name; // 128 bytes
    bytes32 symbol;
    uint8 decimals;
}

struct AddPoolMsg {
    uint64 poolId;
}

struct AddTrancheMsg {
    uint64 poolId;
    bytes16 tranche;
    bytes name; // 128 bytes
    bytes32 symbol;
    uint8 decimals;
    bytes32 hook;
}

struct AllowAssetMsg {
    uint64 poolId;
    uint128 assetId;
}

struct DisallowAssetMsg {
    uint64 poolId;
    uint128 assetId;
}

struct TransferAssetsMsg {
    uint128 assetId;
    bytes32 receiver;
    uint128 amount;
}

library DeserializationLib {
    using BytesLib for bytes;
    using CastLib for bytes;
    using CastLib for bytes32;

    function messageType(bytes memory _msg) public pure returns (MessageType) {
        return MessageType(_msg.toUint8(0));
    }

    function deserializeRegisterAssetMsg(bytes calldata message) public pure returns (RegisterAssetMsg memory) {
        require(messageType(message) == MessageType.RegisterAsset, "Deserialization error");
        return
            RegisterAssetMsg(message.toUint64(1), message.slice(9, 128), message.toBytes32(137), message.toUint8(169));
    }

    function deserializeTransferAssetsMsg(bytes calldata message) public pure returns (TransferAssetsMsg memory) {
        require(messageType(message) == MessageType.TransferAssets, "Deserialization error");
        return TransferAssetsMsg(message.toUint64(1), message.toBytes32(9), message.toUint128(39));
    }
}

library SerializationLib {
    using CastLib for string;

    function serialize(RegisterAssetMsg calldata data) public pure returns (bytes memory) {
        return abi.encodePacked(uint8(MessageType.RegisterAsset), data.assetId, data.name, data.symbol, data.decimals);
    }

    function serialize(AddPoolMsg calldata data) public pure returns (bytes memory) {
        return abi.encodePacked(uint8(MessageType.AddPool), data.poolId);
    }

    function serialize(AddTrancheMsg calldata data) public pure returns (bytes memory) {
        return abi.encodePacked(
            uint8(MessageType.AddShareClass),
            data.poolId,
            data.tranche,
            data.name, /*TODO: fix me, should be 128 bytes*/
            data.symbol,
            data.decimals,
            data.hook
        );
    }

    function serialize(AllowAssetMsg calldata data) public pure returns (bytes memory) {
        return abi.encodePacked(uint8(MessageType.AllowAsset), data.poolId, data.assetId);
    }

    function serialize(DisallowAssetMsg calldata data) public pure returns (bytes memory) {
        return abi.encodePacked(uint8(MessageType.DisallowAsset), data.poolId, data.assetId);
    }

    function serialize(TransferAssetsMsg calldata data) public pure returns (bytes memory) {
        return abi.encodePacked(uint8(MessageType.TransferAssets), data.assetId, data.receiver, data.amount);
    }
}

using SerializationLib for RegisterAssetMsg global;
using SerializationLib for AddPoolMsg global;
using SerializationLib for AddTrancheMsg global;
using SerializationLib for AllowAssetMsg global;
using SerializationLib for DisallowAssetMsg global;
using SerializationLib for TransferAssetsMsg global;
