// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

enum MessageType {
    /// @dev Placeholder for null message type
    Invalid,
    // -- Gateway messages 1 - 4
    MessageProof,
    InitiateMessageRecovery,
    DisputeMessageRecovery,
    Batch,
    // -- Root messages 5 - 7
    ScheduleUpgrade,
    CancelUpgrade,
    RecoverTokens,
    // -- Gas messages 8
    UpdateGasPrice,
    // -- Pool manager messages 9 - 18
    RegisterAsset,
    NotifyPool,
    NotifyShareClass,
    AllowAsset,
    DisallowAsset,
    UpdateShareClassPrice,
    UpdateShareClassMetadata,
    UpdateShareClassHook,
    TransferShares,
    UpdateRestriction,
    // -- Investment manager messages 19 - 27
    DepositRequest,
    RedeemRequest,
    FulfilledDepositRequest,
    FulfilledRedeemRequest,
    CancelDepositRequest,
    CancelRedeemRequest,
    FulfilledCancelDepositRequest,
    FulfilledCancelRedeemRequest,
    TriggerRedeemRequest
}

enum MessageCategory {
    Invalid,
    Gateway,
    Root,
    Gas,
    Pool,
    Investment,
    Other
}

library MessageLib {
    using MessageLib for bytes;
    using BytesLib for bytes;
    using CastLib for *;

    error UnknownMessageType();

    // Hardcoded message lenghts                 0---1---2---3---4---5---6---7---8---9---10--11--12--13--14--15--
    bytes32 constant MESSAGE_LENGTHS_00_15 = hex"000000200040004000000020002000800018aaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    // Hardcoded message lengths                 16--17--18--19--20--21--22--23--24--25--26--27--
    bytes32 constant MESSAGE_LENGTHS_16_31 = hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    function messageType(bytes memory message) internal pure returns (MessageType) {
        return MessageType(message.toUint8(0));
    }

    function messageCode(bytes memory message) internal pure returns (uint8) {
        return message.toUint8(0);
    }

    function length(MessageType kind) internal pure returns (uint16) {
        /*
        if (code <= 15) {
            uint8 index = code * 2;
            return uint16(uint8(MESSAGE_LENGTHS_00_15[index])) << 8 + uint8(MESSAGE_LENGTHS_00_15[index + 1]);
        } else if (code <= uint8(type(MessageType).max)) {
            uint8 index = code * 2 - 16;
            return uint16(uint8(MESSAGE_LENGTHS_00_15[index])) << 8 + uint8(MESSAGE_LENGTHS_00_15[index + 1]);
        } else {
            revert UnknownMessageType();
        }
        */
    }

    function category(uint8 code) internal pure returns (MessageCategory) {
        if (code == 0) {
            return MessageCategory.Invalid;
        } else if (code >= 1 && code <= 4) {
            return MessageCategory.Gateway;
        } else if (code >= 5 && code <= 7) {
            return MessageCategory.Root;
        } else if (code == 8) {
            return MessageCategory.Gas;
        } else if (code >= 9 && code <= 18) {
            return MessageCategory.Pool;
        } else if (code >= 19 && code <= 27) {
            return MessageCategory.Investment;
        } else {
            return MessageCategory.Other;
        }
    }

    //---------------------------------------
    //    MessageProof
    //---------------------------------------

    struct MessageProof {
        bytes32 hash;
    }

    function deserializeMessageProof(bytes memory data) internal pure returns (MessageProof memory) {
        require(messageType(data) == MessageType.MessageProof, UnknownMessageType());
        return MessageProof({hash: data.toBytes32(1)});
    }

    function serialize(MessageProof memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.MessageProof, t.hash);
    }

    //---------------------------------------
    //    InitiateMessageRecovery
    //---------------------------------------

    struct InitiateMessageRecovery {
        bytes32 hash;
        bytes32 adapter;
    }

    function deserializeInitiateMessageRecovery(bytes memory data)
        internal
        pure
        returns (InitiateMessageRecovery memory)
    {
        require(messageType(data) == MessageType.InitiateMessageRecovery, UnknownMessageType());
        return InitiateMessageRecovery({hash: data.toBytes32(1), adapter: data.toBytes32(33)});
    }

    function serialize(InitiateMessageRecovery memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.InitiateMessageRecovery, t.hash, t.adapter);
    }

    //---------------------------------------
    //    DisputeMessageRecovery
    //---------------------------------------

    struct DisputeMessageRecovery {
        bytes32 hash;
        bytes32 adapter;
    }

    function deserializeDisputeMessageRecovery(bytes memory data)
        internal
        pure
        returns (DisputeMessageRecovery memory)
    {
        require(messageType(data) == MessageType.DisputeMessageRecovery, UnknownMessageType());
        return DisputeMessageRecovery({hash: data.toBytes32(1), adapter: data.toBytes32(33)});
    }

    function serialize(DisputeMessageRecovery memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.DisputeMessageRecovery, t.hash, t.adapter);
    }

    //---------------------------------------
    //    ScheduleUpgrade
    //---------------------------------------

    struct ScheduleUpgrade {
        bytes32 target;
    }

    function deserializeScheduleUpgrade(bytes memory data) internal pure returns (ScheduleUpgrade memory) {
        require(messageType(data) == MessageType.ScheduleUpgrade, UnknownMessageType());
        return ScheduleUpgrade({target: data.toBytes32(1)});
    }

    function serialize(ScheduleUpgrade memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.ScheduleUpgrade, t.target);
    }

    //---------------------------------------
    //    CancelUpgrade
    //---------------------------------------

    struct CancelUpgrade {
        bytes32 target;
    }

    function deserializeCancelUpgrade(bytes memory data) internal pure returns (CancelUpgrade memory) {
        require(messageType(data) == MessageType.CancelUpgrade, UnknownMessageType());
        return CancelUpgrade({target: data.toBytes32(1)});
    }

    function serialize(CancelUpgrade memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.CancelUpgrade, t.target);
    }

    //---------------------------------------
    //    RecoverTokens
    //---------------------------------------

    struct RecoverTokens {
        bytes32 target;
        bytes32 token;
        bytes32 to;
        uint256 amount;
    }

    function deserializeRecoverTokens(bytes memory data) internal pure returns (RecoverTokens memory) {
        require(messageType(data) == MessageType.RecoverTokens, UnknownMessageType());
        return RecoverTokens({
            target: data.toBytes32(1),
            token: data.toBytes32(33),
            to: data.toBytes32(65),
            amount: data.toUint256(97)
        });
    }

    function serialize(RecoverTokens memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.RecoverTokens, t.target, t.token, t.to, t.amount);
    }

    //---------------------------------------
    //    UpdateGasPrice
    //---------------------------------------

    struct UpdateGasPrice {
        uint128 price;
        uint64 timestamp;
    }

    function deserializeUpdateGasPrice(bytes memory data) internal pure returns (UpdateGasPrice memory) {
        require(messageType(data) == MessageType.UpdateGasPrice, UnknownMessageType());
        return UpdateGasPrice({price: data.toUint128(1), timestamp: data.toUint64(17)});
    }

    function serialize(UpdateGasPrice memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.UpdateGasPrice, t.price, t.timestamp);
    }

    //---------------------------------------
    //    RegisterAsset
    //---------------------------------------

    struct RegisterAsset {
        uint128 assetId;
        string name; // Fixed to 128 bytes
        bytes32 symbol; // utf8
        uint8 decimals;
    }

    function deserializeRegisterAsset(bytes memory data) internal pure returns (RegisterAsset memory) {
        require(messageType(data) == MessageType.RegisterAsset, UnknownMessageType());
        return RegisterAsset({
            assetId: data.toUint128(1),
            name: data.slice(17, 128).bytes128ToString(),
            symbol: data.toBytes32(145),
            decimals: data.toUint8(177)
        });
    }

    function serialize(RegisterAsset memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            MessageType.RegisterAsset, t.assetId, bytes(t.name).sliceZeroPadded(0, 128), t.symbol, t.decimals
        );
    }

    //---------------------------------------
    //    NotifyPool
    //---------------------------------------

    struct NotifyPool {
        uint64 poolId;
    }

    function deserializeNotifyPool(bytes memory data) internal pure returns (NotifyPool memory) {
        require(messageType(data) == MessageType.NotifyPool, UnknownMessageType());
        return NotifyPool({poolId: data.toUint64(1)});
    }

    function serialize(NotifyPool memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.NotifyPool, t.poolId);
    }

    //---------------------------------------
    //    NotifyShareClass
    //---------------------------------------

    struct NotifyShareClass {
        uint64 poolId;
        bytes16 scId;
        string name; // Fixed to 128 bytes
        bytes32 symbol; // utf8
        uint8 decimals;
        bytes32 hook;
    }

    function deserializeNotifyShareClass(bytes memory data) internal pure returns (NotifyShareClass memory) {
        require(messageType(data) == MessageType.NotifyShareClass, UnknownMessageType());
        return NotifyShareClass({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            name: data.slice(25, 128).bytes128ToString(),
            symbol: data.toBytes32(153),
            decimals: data.toUint8(185),
            hook: data.toBytes32(186)
        });
    }

    function serialize(NotifyShareClass memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            MessageType.NotifyShareClass,
            t.poolId,
            t.scId,
            bytes(t.name).sliceZeroPadded(0, 128),
            t.symbol,
            t.decimals,
            t.hook
        );
    }

    //---------------------------------------
    //    AllowAsset
    //---------------------------------------

    struct AllowAsset {
        uint64 poolId;
        bytes16 scId;
        uint128 assetId;
    }

    function deserializeAllowAsset(bytes memory data) internal pure returns (AllowAsset memory) {
        require(messageType(data) == MessageType.AllowAsset, UnknownMessageType());
        return AllowAsset({poolId: data.toUint64(1), scId: data.toBytes16(9), assetId: data.toUint128(25)});
    }

    function serialize(AllowAsset memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.AllowAsset, t.poolId, t.scId, t.assetId);
    }

    //---------------------------------------
    //    DisallowAsset
    //---------------------------------------

    struct DisallowAsset {
        uint64 poolId;
        bytes16 scId;
        uint128 assetId;
    }

    function deserializeDisallowAsset(bytes memory data) internal pure returns (DisallowAsset memory) {
        require(messageType(data) == MessageType.DisallowAsset, UnknownMessageType());
        return DisallowAsset({poolId: data.toUint64(1), scId: data.toBytes16(9), assetId: data.toUint128(25)});
    }

    function serialize(DisallowAsset memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.DisallowAsset, t.poolId, t.scId, t.assetId);
    }

    //---------------------------------------
    //    UpdateShareClassPrice
    //---------------------------------------

    struct UpdateShareClassPrice {
        uint64 poolId;
        bytes16 scId;
        uint128 assetId;
        uint128 price;
        uint64 timestamp;
    }

    function deserializeUpdateShareClassPrice(bytes memory data) internal pure returns (UpdateShareClassPrice memory) {
        require(messageType(data) == MessageType.UpdateShareClassPrice, UnknownMessageType());
        return UpdateShareClassPrice({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            assetId: data.toUint128(25),
            price: data.toUint128(41),
            timestamp: data.toUint64(57)
        });
    }

    function serialize(UpdateShareClassPrice memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.UpdateShareClassPrice, t.poolId, t.scId, t.assetId, t.price, t.timestamp);
    }

    //---------------------------------------
    //    UpdateShareClassMetadata
    //---------------------------------------

    struct UpdateShareClassMetadata {
        uint64 poolId;
        bytes16 scId;
        string name; // Fixed to 128 bytes
        bytes32 symbol; // utf8
    }

    function deserializeUpdateShareClassMetadata(bytes memory data)
        internal
        pure
        returns (UpdateShareClassMetadata memory)
    {
        require(messageType(data) == MessageType.UpdateShareClassMetadata, UnknownMessageType());
        return UpdateShareClassMetadata({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            name: data.slice(25, 128).bytes128ToString(),
            symbol: data.toBytes32(153)
        });
    }

    function serialize(UpdateShareClassMetadata memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            MessageType.UpdateShareClassMetadata, t.poolId, t.scId, bytes(t.name).sliceZeroPadded(0, 128), t.symbol
        );
    }

    //---------------------------------------
    //    UpdateShareClassHook
    //---------------------------------------

    struct UpdateShareClassHook {
        uint64 poolId;
        bytes16 scId;
        bytes32 hook;
    }

    function deserializeUpdateShareClassHook(bytes memory data) internal pure returns (UpdateShareClassHook memory) {
        require(messageType(data) == MessageType.UpdateShareClassHook, UnknownMessageType());
        return UpdateShareClassHook({poolId: data.toUint64(1), scId: data.toBytes16(9), hook: data.toBytes32(25)});
    }

    function serialize(UpdateShareClassHook memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.UpdateShareClassHook, t.poolId, t.scId, t.hook);
    }

    //---------------------------------------
    //    TransferShares
    //---------------------------------------

    struct TransferShares {
        uint64 poolId;
        bytes16 scId;
        bytes32 recipient;
        uint128 amount;
    }

    function deserializeTransferShares(bytes memory data) internal pure returns (TransferShares memory) {
        require(messageType(data) == MessageType.TransferShares, UnknownMessageType());
        return TransferShares({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            recipient: data.toBytes32(25),
            amount: data.toUint128(57)
        });
    }

    function serialize(TransferShares memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.TransferShares, t.poolId, t.scId, t.recipient, t.amount);
    }

    //---------------------------------------
    //    UpdateRestriction
    //---------------------------------------

    struct UpdateRestriction {
        uint64 poolId;
        bytes16 scId;
        bytes payload;
    }

    function deserializeUpdateRestriction(bytes memory data) internal pure returns (UpdateRestriction memory) {
        require(messageType(data) == MessageType.UpdateRestriction, UnknownMessageType());
        return UpdateRestriction({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            payload: data.slice(25, data.length - 25)
        });
    }

    function serialize(UpdateRestriction memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.UpdateRestriction, t.poolId, t.scId, t.payload);
    }

    //---------------------------------------
    //    DepositRequest
    //---------------------------------------

    struct DepositRequest {
        uint64 poolId;
        bytes16 scId;
        bytes32 investor;
        uint128 assetId;
        uint128 amount;
    }

    function deserializeDepositRequest(bytes memory data) internal pure returns (DepositRequest memory) {
        require(messageType(data) == MessageType.DepositRequest, UnknownMessageType());
        return DepositRequest({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            investor: data.toBytes32(25),
            assetId: data.toUint128(57),
            amount: data.toUint128(73)
        });
    }

    function serialize(DepositRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.DepositRequest, t.poolId, t.scId, t.investor, t.assetId, t.amount);
    }

    //---------------------------------------
    //    RedeemRequest
    //---------------------------------------

    struct RedeemRequest {
        uint64 poolId;
        bytes16 scId;
        bytes32 investor;
        uint128 assetId;
        uint128 amount;
    }

    function deserializeRedeemRequest(bytes memory data) internal pure returns (RedeemRequest memory) {
        require(messageType(data) == MessageType.RedeemRequest, UnknownMessageType());
        return RedeemRequest({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            investor: data.toBytes32(25),
            assetId: data.toUint128(57),
            amount: data.toUint128(73)
        });
    }

    function serialize(RedeemRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.RedeemRequest, t.poolId, t.scId, t.investor, t.assetId, t.amount);
    }

    //---------------------------------------
    //    CancelDepositRequest
    //---------------------------------------

    struct CancelDepositRequest {
        uint64 poolId;
        bytes16 scId;
        bytes32 investor;
        uint128 assetId;
    }

    function deserializeCancelDepositRequest(bytes memory data) internal pure returns (CancelDepositRequest memory) {
        require(messageType(data) == MessageType.CancelDepositRequest, UnknownMessageType());
        return CancelDepositRequest({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            investor: data.toBytes32(25),
            assetId: data.toUint128(57)
        });
    }

    function serialize(CancelDepositRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.CancelDepositRequest, t.poolId, t.scId, t.investor, t.assetId);
    }

    //---------------------------------------
    //    CancelRedeemRequest
    //---------------------------------------

    struct CancelRedeemRequest {
        uint64 poolId;
        bytes16 scId;
        bytes32 investor;
        uint128 assetId;
    }

    function deserializeCancelRedeemRequest(bytes memory data) internal pure returns (CancelRedeemRequest memory) {
        require(messageType(data) == MessageType.CancelRedeemRequest, UnknownMessageType());
        return CancelRedeemRequest({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            investor: data.toBytes32(25),
            assetId: data.toUint128(57)
        });
    }

    function serialize(CancelRedeemRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.CancelRedeemRequest, t.poolId, t.scId, t.investor, t.assetId);
    }

    //---------------------------------------
    //    FulfilledDepositRequest
    //---------------------------------------

    struct FulfilledDepositRequest {
        uint64 poolId;
        bytes16 scId;
        bytes32 investor;
        uint128 assetId;
        uint128 assetAmount;
        uint128 shareAmount;
    }

    function deserializeFulfilledDepositRequest(bytes memory data)
        internal
        pure
        returns (FulfilledDepositRequest memory)
    {
        require(messageType(data) == MessageType.FulfilledDepositRequest, UnknownMessageType());
        return FulfilledDepositRequest({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            investor: data.toBytes32(25),
            assetId: data.toUint128(57),
            assetAmount: data.toUint128(73),
            shareAmount: data.toUint128(89)
        });
    }

    function serialize(FulfilledDepositRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            MessageType.FulfilledDepositRequest, t.poolId, t.scId, t.investor, t.assetId, t.assetAmount, t.shareAmount
        );
    }

    //---------------------------------------
    //    FulfilledRedeemRequest
    //---------------------------------------

    struct FulfilledRedeemRequest {
        uint64 poolId;
        bytes16 scId;
        bytes32 investor;
        uint128 assetId;
        uint128 assetAmount;
        uint128 shareAmount;
    }

    function deserializeFulfilledRedeemRequest(bytes memory data)
        internal
        pure
        returns (FulfilledRedeemRequest memory)
    {
        require(messageType(data) == MessageType.FulfilledRedeemRequest, UnknownMessageType());
        return FulfilledRedeemRequest({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            investor: data.toBytes32(25),
            assetId: data.toUint128(57),
            assetAmount: data.toUint128(73),
            shareAmount: data.toUint128(89)
        });
    }

    function serialize(FulfilledRedeemRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            MessageType.FulfilledRedeemRequest, t.poolId, t.scId, t.investor, t.assetId, t.assetAmount, t.shareAmount
        );
    }

    //---------------------------------------
    //    FulfilledCancelDepositRequest
    //---------------------------------------

    struct FulfilledCancelDepositRequest {
        uint64 poolId;
        bytes16 scId;
        bytes32 investor;
        uint128 assetId;
        uint128 cancelledAmount;
    }

    function deserializeFulfilledCancelDepositRequest(bytes memory data)
        internal
        pure
        returns (FulfilledCancelDepositRequest memory)
    {
        require(messageType(data) == MessageType.FulfilledCancelDepositRequest, UnknownMessageType());
        return FulfilledCancelDepositRequest({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            investor: data.toBytes32(25),
            assetId: data.toUint128(57),
            cancelledAmount: data.toUint128(73)
        });
    }

    function serialize(FulfilledCancelDepositRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            MessageType.FulfilledCancelDepositRequest, t.poolId, t.scId, t.investor, t.assetId, t.cancelledAmount
        );
    }

    //---------------------------------------
    //    FulfilledCancelRedeemRequest
    //---------------------------------------

    struct FulfilledCancelRedeemRequest {
        uint64 poolId;
        bytes16 scId;
        bytes32 investor;
        uint128 assetId;
        uint128 cancelledShares;
    }

    function deserializeFulfilledCancelRedeemRequest(bytes memory data)
        internal
        pure
        returns (FulfilledCancelRedeemRequest memory)
    {
        require(messageType(data) == MessageType.FulfilledCancelRedeemRequest, UnknownMessageType());
        return FulfilledCancelRedeemRequest({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            investor: data.toBytes32(25),
            assetId: data.toUint128(57),
            cancelledShares: data.toUint128(73)
        });
    }

    function serialize(FulfilledCancelRedeemRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            MessageType.FulfilledCancelRedeemRequest, t.poolId, t.scId, t.investor, t.assetId, t.cancelledShares
        );
    }

    //---------------------------------------
    //    TriggerRedeemRequest
    //---------------------------------------

    struct TriggerRedeemRequest {
        uint64 poolId;
        bytes16 scId;
        bytes32 investor;
        uint128 assetId;
        uint128 shares;
    }

    function deserializeTriggerRedeemRequest(bytes memory data) internal pure returns (TriggerRedeemRequest memory) {
        require(messageType(data) == MessageType.TriggerRedeemRequest, UnknownMessageType());
        return TriggerRedeemRequest({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            investor: data.toBytes32(25),
            assetId: data.toUint128(57),
            shares: data.toUint128(73)
        });
    }

    function serialize(TriggerRedeemRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(MessageType.TriggerRedeemRequest, t.poolId, t.scId, t.investor, t.assetId, t.shares);
    }
}
