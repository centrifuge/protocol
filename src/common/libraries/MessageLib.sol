// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {JournalEntry, JournalEntryLib} from "src/common/libraries/JournalEntryLib.sol";

enum MessageType {
    /// @dev Placeholder for null message type
    Invalid,
    // -- Gateway messages
    MessageProof,
    InitiateMessageRecovery,
    DisputeMessageRecovery,
    // -- Root messages
    ScheduleUpgrade,
    CancelUpgrade,
    RecoverTokens,
    // -- Pool manager messages
    RegisterAsset,
    NotifyPool,
    NotifyShareClass,
    UpdateShareClassPrice,
    UpdateShareClassMetadata,
    UpdateShareClassHook,
    TransferShares,
    UpdateRestriction,
    UpdateContract,
    // -- Investment manager messages
    DepositRequest,
    RedeemRequest,
    FulfilledDepositRequest,
    FulfilledRedeemRequest,
    CancelDepositRequest,
    CancelRedeemRequest,
    FulfilledCancelDepositRequest,
    FulfilledCancelRedeemRequest,
    TriggerRedeemRequest,
    // -- BalanceSheetManager messages
    UpdateHoldingAmount,
    UpdateHoldingValue,
    UpdateShares,
    UpdateJournal,
    TriggerUpdateHoldingAmount,
    TriggerUpdateShares
}

enum UpdateRestrictionType {
    /// @dev Placeholder for null update restriction type
    Invalid,
    Member,
    Freeze,
    Unfreeze
}

enum UpdateContractType {
    /// @dev Placeholder for null update restriction type
    Invalid,
    VaultUpdate,
    Permission,
    MaxPriceAge
}

/// @dev Used internally in the VaultUpdateMessage (not represent a submessage)
enum VaultUpdateKind {
    DeployAndLink,
    Link,
    Unlink
}

library MessageLib {
    using MessageLib for bytes;
    using BytesLib for bytes;
    using JournalEntryLib for *;
    using CastLib for *;

    error UnknownMessageType();

    /// @dev Each enum value corresponds to an array index holding the fixed length of the message.
    ///      If a message has dynamic length, the value represents its base size (minimum static part).
    function _messageLengths(uint16 kind) private pure returns (uint16) {
        if (kind == uint16(MessageType.Invalid)) return 0; // Invalid placeholder
        if (kind == uint16(MessageType.MessageProof)) return 34;
        if (kind == uint16(MessageType.InitiateMessageRecovery)) return 68;
        if (kind == uint16(MessageType.DisputeMessageRecovery)) return 68;
        if (kind == uint16(MessageType.ScheduleUpgrade)) return 34;
        if (kind == uint16(MessageType.CancelUpgrade)) return 34;
        if (kind == uint16(MessageType.RecoverTokens)) return 162;
        if (kind == uint16(MessageType.RegisterAsset)) return 179;
        if (kind == uint16(MessageType.NotifyPool)) return 10;
        if (kind == uint16(MessageType.NotifyShareClass)) return 251;
        if (kind == uint16(MessageType.UpdateShareClassPrice)) return 66;
        if (kind == uint16(MessageType.UpdateShareClassMetadata)) return 186;
        if (kind == uint16(MessageType.UpdateShareClassHook)) return 58;
        if (kind == uint16(MessageType.TransferShares)) return 74;
        if (kind == uint16(MessageType.UpdateRestriction)) return 26; // dynamic
        if (kind == uint16(MessageType.UpdateContract)) return 58; // dynamic
        if (kind == uint16(MessageType.DepositRequest)) return 90;
        if (kind == uint16(MessageType.RedeemRequest)) return 90;
        if (kind == uint16(MessageType.FulfilledDepositRequest)) return 106;
        if (kind == uint16(MessageType.FulfilledRedeemRequest)) return 106;
        if (kind == uint16(MessageType.CancelDepositRequest)) return 74;
        if (kind == uint16(MessageType.CancelRedeemRequest)) return 74;
        if (kind == uint16(MessageType.FulfilledCancelDepositRequest)) return 90;
        if (kind == uint16(MessageType.FulfilledCancelRedeemRequest)) return 90;
        if (kind == uint16(MessageType.TriggerRedeemRequest)) return 90;
        if (kind == uint16(MessageType.UpdateHoldingAmount)) return 115; // dynamic
        if (kind == uint16(MessageType.UpdateHoldingValue)) return 66;
        if (kind == uint16(MessageType.UpdateShares)) return 99;
        // if (kind == uint16(MessageType.ApprovedDeposits)) return 58;
        // if (kind == uint16(MessageType.RevokedShares)) return 58;
        if (kind == uint16(MessageType.UpdateJournal)) return 10; // dynamic
        if (kind == uint16(MessageType.TriggerUpdateHoldingAmount)) return 108; // dynamic
        if (kind == uint16(MessageType.TriggerUpdateShares)) return 92;
        revert UnknownMessageType();
    }

    function messageType(bytes memory message) internal pure returns (MessageType) {
        return MessageType(message.toUint16(0));
    }

    function messageCode(bytes memory message) internal pure returns (uint16) {
        return message.toUint16(0);
    }

    function messageLength(bytes memory message) internal pure returns (uint16 length) {
        uint16 kind = message.toUint16(0);
        length = _messageLengths(kind);

        // Handle dynamic-length messages separately:
        if (kind == uint16(MessageType.UpdateRestriction) || kind == uint16(MessageType.UpdateContract)) {
            length += 2 + message.toUint16(length);
        } else if (
            kind == uint16(MessageType.UpdateHoldingAmount) || kind == uint16(MessageType.TriggerUpdateHoldingAmount)
                || kind == uint16(MessageType.UpdateJournal)
        ) {
            uint16 debitsByteLen = message.toUint16(length);
            uint16 creditsByteLen = message.toUint16(length + 2 + debitsByteLen);
            length += 2 + debitsByteLen + 2 + creditsByteLen;
        }

        revert UnknownMessageType();
    }

    function messagePoolId(bytes memory message) internal pure returns (PoolId poolId) {
        uint16 kind = message.toUint16(0);

        // All messages from NotifyPool to TriggetUpdateShares contains a PoolId in position 1.
        if (kind >= uint16(MessageType.NotifyPool) && kind <= uint16(MessageType.TriggerUpdateShares)) {
            return PoolId.wrap(message.toUint64(1));
        } else {
            return PoolId.wrap(0);
        }
    }

    function updateRestrictionType(bytes memory message) internal pure returns (UpdateRestrictionType) {
        return UpdateRestrictionType(message.toUint8(0));
    }

    function updateContractType(bytes memory message) internal pure returns (UpdateContractType) {
        return UpdateContractType(message.toUint8(0));
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
        return abi.encodePacked(uint16(MessageType.MessageProof), t.hash);
    }

    //---------------------------------------
    //    InitiateMessageRecovery
    //---------------------------------------

    struct InitiateMessageRecovery {
        bytes32 hash;
        bytes32 adapter;
        uint16 domainId;
    }

    function deserializeInitiateMessageRecovery(bytes memory data)
        internal
        pure
        returns (InitiateMessageRecovery memory)
    {
        require(messageType(data) == MessageType.InitiateMessageRecovery, UnknownMessageType());
        return
            InitiateMessageRecovery({hash: data.toBytes32(1), adapter: data.toBytes32(33), domainId: data.toUint16(65)});
    }

    function serialize(InitiateMessageRecovery memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(MessageType.InitiateMessageRecovery), t.hash, t.adapter, t.domainId);
    }

    //---------------------------------------
    //    DisputeMessageRecovery
    //---------------------------------------

    struct DisputeMessageRecovery {
        bytes32 hash;
        bytes32 adapter;
        uint16 domainId;
    }

    function deserializeDisputeMessageRecovery(bytes memory data)
        internal
        pure
        returns (DisputeMessageRecovery memory)
    {
        require(messageType(data) == MessageType.DisputeMessageRecovery, UnknownMessageType());
        return
            DisputeMessageRecovery({hash: data.toBytes32(1), adapter: data.toBytes32(33), domainId: data.toUint16(65)});
    }

    function serialize(DisputeMessageRecovery memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(MessageType.DisputeMessageRecovery), t.hash, t.adapter, t.domainId);
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
        return abi.encodePacked(uint16(MessageType.ScheduleUpgrade), t.target);
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
        return abi.encodePacked(uint16(MessageType.CancelUpgrade), t.target);
    }

    //---------------------------------------
    //    RecoverTokens
    //---------------------------------------

    struct RecoverTokens {
        bytes32 target;
        bytes32 token;
        uint256 tokenId;
        bytes32 to;
        uint256 amount;
    }

    function deserializeRecoverTokens(bytes memory data) internal pure returns (RecoverTokens memory) {
        require(messageType(data) == MessageType.RecoverTokens, UnknownMessageType());
        return RecoverTokens({
            target: data.toBytes32(1),
            token: data.toBytes32(33),
            tokenId: data.toUint256(65),
            to: data.toBytes32(97),
            amount: data.toUint256(129)
        });
    }

    function serialize(RecoverTokens memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(MessageType.RecoverTokens), t.target, t.token, t.tokenId, t.to, t.amount);
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
            uint16(MessageType.RegisterAsset), t.assetId, bytes(t.name).sliceZeroPadded(0, 128), t.symbol, t.decimals
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
        return abi.encodePacked(uint16(MessageType.NotifyPool), t.poolId);
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
        bytes32 salt;
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
            salt: data.toBytes32(186),
            hook: data.toBytes32(218)
        });
    }

    function serialize(NotifyShareClass memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint16(MessageType.NotifyShareClass),
            t.poolId,
            t.scId,
            bytes(t.name).sliceZeroPadded(0, 128),
            t.symbol,
            t.decimals,
            t.salt,
            t.hook
        );
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
        return abi.encodePacked(
            uint16(MessageType.UpdateShareClassPrice), t.poolId, t.scId, t.assetId, t.price, t.timestamp
        );
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
            uint16(MessageType.UpdateShareClassMetadata),
            t.poolId,
            t.scId,
            bytes(t.name).sliceZeroPadded(0, 128),
            t.symbol
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
        return abi.encodePacked(uint16(MessageType.UpdateShareClassHook), t.poolId, t.scId, t.hook);
    }

    //---------------------------------------
    //    TransferShares
    //---------------------------------------

    struct TransferShares {
        uint64 poolId;
        bytes16 scId;
        bytes32 receiver;
        uint128 amount;
    }

    function deserializeTransferShares(bytes memory data) internal pure returns (TransferShares memory) {
        require(messageType(data) == MessageType.TransferShares, UnknownMessageType());
        return TransferShares({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            receiver: data.toBytes32(25),
            amount: data.toUint128(57)
        });
    }

    function serialize(TransferShares memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(MessageType.TransferShares), t.poolId, t.scId, t.receiver, t.amount);
    }

    //---------------------------------------
    //    UpdateRestriction
    //---------------------------------------

    struct UpdateRestriction {
        uint64 poolId;
        bytes16 scId;
        bytes payload; // As sequence of bytes
    }

    function deserializeUpdateRestriction(bytes memory data) internal pure returns (UpdateRestriction memory) {
        require(messageType(data) == MessageType.UpdateRestriction, UnknownMessageType());

        uint16 payloadLength = data.toUint16(25);
        return UpdateRestriction({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            payload: data.slice(27, payloadLength)
        });
    }

    function serialize(UpdateRestriction memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint16(MessageType.UpdateRestriction), t.poolId, t.scId, uint16(t.payload.length), t.payload
        );
    }

    //---------------------------------------
    //    UpdateRestrictionMember (submsg)
    //---------------------------------------

    struct UpdateRestrictionMember {
        bytes32 user;
        uint64 validUntil;
    }

    function deserializeUpdateRestrictionMember(bytes memory data)
        internal
        pure
        returns (UpdateRestrictionMember memory)
    {
        require(updateRestrictionType(data) == UpdateRestrictionType.Member, UnknownMessageType());

        return UpdateRestrictionMember({user: data.toBytes32(1), validUntil: data.toUint64(33)});
    }

    function serialize(UpdateRestrictionMember memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateRestrictionType.Member, t.user, t.validUntil);
    }

    //---------------------------------------
    //    UpdateRestrictionFreeze (submsg)
    //---------------------------------------

    struct UpdateRestrictionFreeze {
        bytes32 user;
    }

    function deserializeUpdateRestrictionFreeze(bytes memory data)
        internal
        pure
        returns (UpdateRestrictionFreeze memory)
    {
        require(updateRestrictionType(data) == UpdateRestrictionType.Freeze, UnknownMessageType());

        return UpdateRestrictionFreeze({user: data.toBytes32(1)});
    }

    function serialize(UpdateRestrictionFreeze memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateRestrictionType.Freeze, t.user);
    }

    //---------------------------------------
    //    UpdateRestrictionUnfreeze (submsg)
    //---------------------------------------

    struct UpdateRestrictionUnfreeze {
        bytes32 user;
    }

    function deserializeUpdateRestrictionUnfreeze(bytes memory data)
        internal
        pure
        returns (UpdateRestrictionUnfreeze memory)
    {
        require(updateRestrictionType(data) == UpdateRestrictionType.Unfreeze, UnknownMessageType());

        return UpdateRestrictionUnfreeze({user: data.toBytes32(1)});
    }

    function serialize(UpdateRestrictionUnfreeze memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateRestrictionType.Unfreeze, t.user);
    }

    //---------------------------------------
    //    UpdateContract
    //---------------------------------------

    struct UpdateContract {
        uint64 poolId;
        bytes16 scId;
        bytes32 target;
        bytes payload; // As sequence of bytes
    }

    function deserializeUpdateContract(bytes memory data) internal pure returns (UpdateContract memory) {
        require(messageType(data) == MessageType.UpdateContract, UnknownMessageType());
        uint16 payloadLength = data.toUint16(57);
        return UpdateContract({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            target: data.toBytes32(25),
            payload: data.slice(59, payloadLength)
        });
    }

    function serialize(UpdateContract memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint16(MessageType.UpdateContract), t.poolId, t.scId, t.target, uint16(t.payload.length), t.payload
        );
    }

    //---------------------------------------
    //   UpdateContract.VaultUpdate (submsg)
    //---------------------------------------

    struct UpdateContractVaultUpdate {
        bytes32 vaultOrFactory;
        uint128 assetId;
        uint8 kind;
    }

    function deserializeUpdateContractVaultUpdate(bytes memory data)
        internal
        pure
        returns (UpdateContractVaultUpdate memory)
    {
        require(updateContractType(data) == UpdateContractType.VaultUpdate, UnknownMessageType());

        return UpdateContractVaultUpdate({
            vaultOrFactory: data.toBytes32(1),
            assetId: data.toUint128(33),
            kind: data.toUint8(49)
        });
    }

    function serialize(UpdateContractVaultUpdate memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateContractType.VaultUpdate, t.vaultOrFactory, t.assetId, t.kind);
    }

    //---------------------------------------
    //   UpdateContract.Permission (submsg)
    //---------------------------------------

    struct UpdateContractPermission {
        bytes32 who;
        bool allowed;
    }

    function deserializeUpdateContractPermission(bytes memory data)
        internal
        pure
        returns (UpdateContractPermission memory)
    {
        require(updateContractType(data) == UpdateContractType.Permission, UnknownMessageType());

        return UpdateContractPermission({who: data.toBytes32(1), allowed: data.toBool(33)});
    }

    function serialize(UpdateContractPermission memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateContractType.Permission, t.who, t.allowed);
    }

    //---------------------------------------
    //   UpdateContract.MaxPriceAge (submsg)
    //---------------------------------------

    struct UpdateContractMaxPriceAge {
        bytes32 vault;
        uint64 maxPriceAge;
    }

    function deserializeUpdateContractMaxPriceAge(bytes memory data)
        internal
        pure
        returns (UpdateContractMaxPriceAge memory)
    {
        require(updateContractType(data) == UpdateContractType.MaxPriceAge, UnknownMessageType());

        return UpdateContractMaxPriceAge({vault: data.toBytes32(1), maxPriceAge: data.toUint64(33)});
    }

    function serialize(UpdateContractMaxPriceAge memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateContractType.MaxPriceAge, t.vault, t.maxPriceAge);
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
        return abi.encodePacked(uint16(MessageType.DepositRequest), t.poolId, t.scId, t.investor, t.assetId, t.amount);
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
        return abi.encodePacked(uint16(MessageType.RedeemRequest), t.poolId, t.scId, t.investor, t.assetId, t.amount);
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
        return abi.encodePacked(uint16(MessageType.CancelDepositRequest), t.poolId, t.scId, t.investor, t.assetId);
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
        return abi.encodePacked(uint16(MessageType.CancelRedeemRequest), t.poolId, t.scId, t.investor, t.assetId);
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
            uint16(MessageType.FulfilledDepositRequest),
            t.poolId,
            t.scId,
            t.investor,
            t.assetId,
            t.assetAmount,
            t.shareAmount
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
            uint16(MessageType.FulfilledRedeemRequest),
            t.poolId,
            t.scId,
            t.investor,
            t.assetId,
            t.assetAmount,
            t.shareAmount
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
            uint16(MessageType.FulfilledCancelDepositRequest),
            t.poolId,
            t.scId,
            t.investor,
            t.assetId,
            t.cancelledAmount
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
            uint16(MessageType.FulfilledCancelRedeemRequest), t.poolId, t.scId, t.investor, t.assetId, t.cancelledShares
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
        return abi.encodePacked(
            uint16(MessageType.TriggerRedeemRequest), t.poolId, t.scId, t.investor, t.assetId, t.shares
        );
    }

    //---------------------------------------
    //    UpdateHoldingAmount
    //---------------------------------------

    struct UpdateHoldingAmount {
        uint64 poolId;
        bytes16 scId;
        uint128 assetId;
        bytes32 who;
        uint128 amount;
        uint128 pricePerUnit;
        uint64 timestamp;
        bool isIncrease; // Signals whether this is an increase or a decrease
        JournalEntry[] debits; // As sequence of bytes
        JournalEntry[] credits; // As sequence of bytes
    }

    function deserializeUpdateHoldingAmount(bytes memory data) internal pure returns (UpdateHoldingAmount memory h) {
        require(messageType(data) == MessageType.UpdateHoldingAmount, "UnknownMessageType");

        uint16 debitsByteLen = data.toUint16(114);
        uint16 creditsByteLen = data.toUint16(116 + debitsByteLen);

        return UpdateHoldingAmount({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            assetId: data.toUint128(25),
            who: data.toBytes32(41),
            amount: data.toUint128(73),
            pricePerUnit: data.toUint128(89),
            timestamp: data.toUint64(105),
            isIncrease: data.toBool(113),
            // Skip 2 bytes for sequence length at 114
            debits: data.toJournalEntries(116, debitsByteLen),
            // Skip 2 bytes for sequence length at 116 + debitsByteLen
            credits: data.toJournalEntries(118 + debitsByteLen, creditsByteLen)
        });
    }

    function serialize(UpdateHoldingAmount memory t) public pure returns (bytes memory) {
        bytes memory debits = t.debits.toBytes();
        bytes memory credits = t.credits.toBytes();

        bytes memory partial1 = abi.encodePacked(
            uint16(MessageType.UpdateHoldingAmount),
            t.poolId,
            t.scId,
            t.assetId,
            t.who,
            t.amount,
            t.pricePerUnit,
            t.timestamp,
            t.isIncrease
        );

        // partial1 extracted to avoid stack too deep issue
        return abi.encodePacked(partial1, uint16(debits.length), debits, uint16(credits.length), credits);
    }

    //---------------------------------------
    //    UpdateHoldingValue
    //---------------------------------------

    struct UpdateHoldingValue {
        uint64 poolId;
        bytes16 scId;
        uint128 assetId;
        uint128 pricePerUnit;
        uint64 timestamp;
    }

    function deserializeUpdateHoldingValue(bytes memory data) internal pure returns (UpdateHoldingValue memory h) {
        require(messageType(data) == MessageType.UpdateHoldingValue, "UnknownMessageType");

        return UpdateHoldingValue({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            assetId: data.toUint128(25),
            pricePerUnit: data.toUint128(41),
            timestamp: data.toUint64(57)
        });
    }

    function serialize(UpdateHoldingValue memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint16(MessageType.UpdateHoldingValue), t.poolId, t.scId, t.assetId, t.pricePerUnit, t.timestamp
        );
    }

    //---------------------------------------
    //    UpdateShares
    //---------------------------------------

    struct UpdateShares {
        uint64 poolId;
        bytes16 scId;
        bytes32 who;
        uint128 pricePerShare;
        uint128 shares;
        uint64 timestamp;
        bool isIssuance;
    }

    function deserializeUpdateShares(bytes memory data) internal pure returns (UpdateShares memory) {
        require(messageType(data) == MessageType.UpdateShares, UnknownMessageType());

        return UpdateShares({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            who: data.toBytes32(25),
            pricePerShare: data.toUint128(57),
            shares: data.toUint128(73),
            timestamp: data.toUint64(89),
            isIssuance: data.toBool(97)
        });
    }

    function serialize(UpdateShares memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint16(MessageType.UpdateShares),
            t.poolId,
            t.scId,
            t.who,
            t.pricePerShare,
            t.shares,
            t.timestamp,
            t.isIssuance
        );
    }

    //---------------------------------------
    //    ApprovedDeposits
    //---------------------------------------

    // struct ApprovedDeposits {
    //     uint64 poolId;
    //     bytes16 scId;
    //     uint128 assetId;
    //     // TODO: Maybe include pricePoolPerAsset for BSM response
    //     uint128 assetAmount;
    // }

    // function deserializeApprovedDeposits(bytes memory data) internal pure returns (ApprovedDeposits memory) {
    //     require(messageType(data) == MessageType.ApprovedDeposits, UnknownMessageType());

    //     return ApprovedDeposits({
    //         poolId: data.toUint64(1),
    //         scId: data.toBytes16(9),
    //         assetId: data.toUint128(25),
    //         assetAmount: data.toUint128(41)
    //     });
    // }

    // function serialize(ApprovedDeposits memory t) internal pure returns (bytes memory) {
    //     return abi.encodePacked(uint16(MessageType.ApprovedDeposits), t.poolId, t.scId, t.assetId, t.assetAmount);
    // }

    //---------------------------------------
    //    RevokedShares
    //---------------------------------------

    // struct RevokedShares {
    //     uint64 poolId;
    //     bytes16 scId;
    //     uint128 assetId;
    //     uint128 assetAmount;
    // }

    // function deserializeRevokedShares(bytes memory data) internal pure returns (RevokedShares memory) {
    //     require(messageType(data) == MessageType.RevokedShares, UnknownMessageType());

    //     return RevokedShares({
    //         poolId: data.toUint64(1),
    //         scId: data.toBytes16(9),
    //         assetId: data.toUint128(25),
    //         assetAmount: data.toUint128(41)
    //     });
    // }

    // function serialize(RevokedShares memory t) internal pure returns (bytes memory) {
    //     return abi.encodePacked(uint16(MessageType.RevokedShares), t.poolId, t.scId, t.assetId, t.assetAmount);
    // }

    //---------------------------------------
    //    UpdateJournal
    //---------------------------------------

    struct UpdateJournal {
        uint64 poolId;
        JournalEntry[] debits; // As sequence of bytes
        JournalEntry[] credits; // As sequence of bytes
    }

    function deserializeUpdateJournal(bytes memory data) internal pure returns (UpdateJournal memory) {
        require(messageType(data) == MessageType.UpdateJournal, UnknownMessageType());

        uint16 debitsByteLen = data.toUint16(9);
        uint16 creditsByteLen = data.toUint16(11 + debitsByteLen);

        return UpdateJournal({
            poolId: data.toUint64(1),
            // Skip 2 bytes for sequence length at 9
            debits: data.toJournalEntries(11, debitsByteLen),
            // Skip 2 bytes for sequence length at 11 + debitsByteLen
            credits: data.toJournalEntries(13 + debitsByteLen, creditsByteLen)
        });
    }

    function serialize(UpdateJournal memory t) internal pure returns (bytes memory) {
        bytes memory debits = t.debits.toBytes();
        bytes memory credits = t.credits.toBytes();

        return abi.encodePacked(
            uint16(MessageType.UpdateJournal), t.poolId, uint16(debits.length), debits, uint16(credits.length), credits
        );
    }

    //---------------------------------------
    //    TriggerUpdateHoldingAmount
    //---------------------------------------

    struct TriggerUpdateHoldingAmount {
        uint64 poolId;
        bytes16 scId;
        uint128 assetId;
        bytes32 who;
        uint128 amount;
        uint128 pricePerUnit;
        bool isIncrease; // Signals whether this is an increase or a decrease
        bool asAllowance; // Signals whether the amount is transferred or allowed to who on the BSM
        JournalEntry[] debits; // As sequence of bytes
        JournalEntry[] credits; // As sequence of bytes
    }

    function deserializeTriggerUpdateHoldingAmount(bytes memory data)
        internal
        pure
        returns (TriggerUpdateHoldingAmount memory h)
    {
        require(messageType(data) == MessageType.TriggerUpdateHoldingAmount, "UnknownMessageType");

        uint16 debitsByteLen = data.toUint16(107);
        uint16 creditsByteLen = data.toUint16(109 + debitsByteLen);

        return TriggerUpdateHoldingAmount({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            assetId: data.toUint128(25),
            who: data.toBytes32(41),
            amount: data.toUint128(73),
            pricePerUnit: data.toUint128(89),
            isIncrease: data.toBool(105),
            asAllowance: data.toBool(106),
            // Skip 2 bytes for sequence length at 107
            debits: data.toJournalEntries(109, debitsByteLen),
            // Skip 2 bytes for sequence length at 109 + debitsByteLen
            credits: data.toJournalEntries(111 + debitsByteLen, creditsByteLen)
        });
    }

    function serialize(TriggerUpdateHoldingAmount memory t) internal pure returns (bytes memory) {
        bytes memory debits = t.debits.toBytes();
        bytes memory credits = t.credits.toBytes();

        bytes memory partial1 = abi.encodePacked(
            uint16(MessageType.TriggerUpdateHoldingAmount),
            t.poolId,
            t.scId,
            t.assetId,
            t.who,
            t.amount,
            t.pricePerUnit,
            t.isIncrease,
            t.asAllowance
        );

        // partial1 extracted to avoid stack too deep issue
        return abi.encodePacked(partial1, uint16(debits.length), debits, uint16(credits.length), credits);
    }

    //---------------------------------------
    //    TriggerUpdateShares
    //---------------------------------------

    struct TriggerUpdateShares {
        uint64 poolId;
        bytes16 scId;
        bytes32 who;
        uint128 pricePerShare;
        uint128 shares;
        bool isIssuance;
        bool asAllowance;
    }

    function deserializeTriggerUpdateShares(bytes memory data) internal pure returns (TriggerUpdateShares memory) {
        require(messageType(data) == MessageType.TriggerUpdateShares, UnknownMessageType());

        return TriggerUpdateShares({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            who: data.toBytes32(25),
            pricePerShare: data.toUint128(57),
            shares: data.toUint128(73),
            isIssuance: data.toBool(89),
            asAllowance: data.toBool(90)
        });
    }

    function serialize(TriggerUpdateShares memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint16(MessageType.TriggerUpdateShares),
            t.poolId,
            t.scId,
            t.who,
            t.pricePerShare,
            t.shares,
            t.isIssuance,
            t.asAllowance
        );
    }
}
