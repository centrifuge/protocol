// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "../../../../src/misc/libraries/BytesLib.sol";

import {MESSAGE_MAX_LENGTH} from "../../../../src/core/messaging/interfaces/IGateway.sol";
import {MessageType, MessageLib, VaultUpdateKind} from "../../../../src/core/messaging/libraries/MessageLib.sol";

import "forge-std/Test.sol";

contract TestMessageLibIds is Test {
    function _prepareFor() private returns (bytes memory buffer) {
        buffer = new bytes(1);
        buffer[0] = 0;
        vm.expectRevert(MessageLib.UnknownMessageType.selector);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeScheduleUpgrade() public {
        MessageLib.deserializeScheduleUpgrade(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeCancelUpgrade() public {
        MessageLib.deserializeCancelUpgrade(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeRegisterAsset() public {
        MessageLib.deserializeRegisterAsset(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeSetPoolAdapters() public {
        MessageLib.deserializeSetPoolAdapters(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeUpdateManager() public {
        MessageLib.deserializeUpdateManager(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeNotifyPool() public {
        MessageLib.deserializeNotifyPool(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeNotifyShareClass() public {
        MessageLib.deserializeNotifyShareClass(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeNotifyPricePoolPerShare() public {
        MessageLib.deserializeNotifyPricePoolPerShare(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeNotifyPricePoolPerAsset() public {
        MessageLib.deserializeNotifyPricePoolPerAsset(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeNotifyShareMetadata() public {
        MessageLib.deserializeNotifyShareMetadata(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeInitiateTransferShares() public {
        MessageLib.deserializeInitiateTransferShares(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeExecuteTransferShares() public {
        MessageLib.deserializeExecuteTransferShares(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeUpdateRestriction() public {
        MessageLib.deserializeUpdateRestriction(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeManagerCall() public {
        MessageLib.deserializeManagerCallFromHub(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeUpdateVault() public {
        MessageLib.deserializeUpdateVault(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeUpdateHoldingAmount() public {
        MessageLib.deserializeUpdateAssets(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeUpdateShares() public {
        MessageLib.deserializeUpdateShares(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeRequest() public {
        MessageLib.deserializeRequest(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeRequestCallback() public {
        MessageLib.deserializeRequestCallback(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeSetRequestManager() public {
        MessageLib.deserializeSetRequestManager(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeManagerCallFromSpoke() public {
        MessageLib.deserializeManagerCallFromSpoke(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeSetPolicy() public {
        MessageLib.deserializeSetPolicy(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeAuthorize() public {
        MessageLib.deserializeAuthorizeSpokeCall(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeUnauthorize() public {
        MessageLib.deserializeUnauthorizeSpokeCall(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testMessageLength() public {
        bytes memory buffer = new bytes(1);
        buffer[0] = bytes1(uint8(type(MessageType).max) + 1);
        vm.expectRevert(MessageLib.UnknownMessageType.selector);
        MessageLib.messageLength(buffer);
    }

    /// @dev _Invalid (kind 0) must be rejected rather than returning length 0.
    /// forge-config: default.allow_internal_expect_revert = true
    function testMessageLengthRejectsInvalid() public {
        bytes memory buffer = new bytes(1);
        buffer[0] = bytes1(uint8(MessageType._Invalid));
        vm.expectRevert(MessageLib.UnknownMessageType.selector);
        MessageLib.messageLength(buffer);
    }
}

// The following tests check that the function composition of deserializing and serializing equals to the identity:
//       I = deserialize º serialize
// NOTE. To fully ensure a good testing, use different values for each field.
contract TestMessageLibIdentities is Test {
    using MessageLib for *;

    function testScheduleUpgrade(bytes32 target) public pure {
        MessageLib.ScheduleUpgrade memory a = MessageLib.ScheduleUpgrade({target: target});
        MessageLib.ScheduleUpgrade memory b = MessageLib.deserializeScheduleUpgrade(a.serialize());

        assertEq(a.target, b.target);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), 0);
        assertEq(a.serialize().messageExtraGasLimit(), 0);
    }

    function testCancelUpgrade(bytes32 target) public pure {
        MessageLib.CancelUpgrade memory a = MessageLib.CancelUpgrade({target: target});
        MessageLib.CancelUpgrade memory b = MessageLib.deserializeCancelUpgrade(a.serialize());

        assertEq(a.target, b.target);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), 0);
        assertEq(a.serialize().messageExtraGasLimit(), 0);
    }

    function testRegisterAsset(uint128 assetId, uint8 decimals) public pure {
        MessageLib.RegisterAsset memory a = MessageLib.RegisterAsset({assetId: assetId, decimals: decimals});
        MessageLib.RegisterAsset memory b = MessageLib.deserializeRegisterAsset(a.serialize());

        assertEq(a.assetId, b.assetId);
        assertEq(a.decimals, b.decimals);

        assertEq(bytes(a.serialize()).length, a.serialize().messageLength());
        assertEq(a.serialize().messagePoolId().raw(), 0);
        assertEq(a.serialize().messageExtraGasLimit(), 0);
    }

    function testSetPoolAdapters(uint64 poolId, uint8 threshold, uint16 targetSessionId, bytes32[] memory adapterList)
        public
        pure
    {
        vm.assume(adapterList.length <= 20);

        MessageLib.SetPoolAdapters memory a = MessageLib.SetPoolAdapters({
            poolId: poolId, threshold: threshold, targetSessionId: targetSessionId, adapterList: adapterList
        });
        MessageLib.SetPoolAdapters memory b = MessageLib.deserializeSetPoolAdapters(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.threshold, b.threshold);
        assertEq(a.targetSessionId, b.targetSessionId);
        assertEq(a.adapterList, b.adapterList);

        assertEq(bytes(a.serialize()).length, a.serialize().messageLength());
        // SetPoolAdapters reports its embedded poolId so the update routes over the pool's own adapters.
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), 0);
    }

    function testNotifyPool(uint64 poolId) public pure {
        MessageLib.NotifyPool memory a = MessageLib.NotifyPool({poolId: poolId});
        MessageLib.NotifyPool memory b = MessageLib.deserializeNotifyPool(a.serialize());

        assertEq(a.poolId, b.poolId);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), 0);
    }

    function testNotifyShareClass(
        uint64 poolId,
        bytes16 scId,
        string calldata name,
        bytes32 symbol,
        uint8 decimals,
        bytes32 salt,
        bytes32 registrar,
        uint128 extraGasLimit,
        bytes memory payload
    ) public pure {
        MessageLib.NotifyShareClass memory a = MessageLib.NotifyShareClass({
            poolId: poolId,
            scId: scId,
            name: name,
            symbol: symbol,
            decimals: decimals,
            salt: salt,
            registrar: registrar,
            extraGasLimit: extraGasLimit,
            payload: payload
        });
        MessageLib.NotifyShareClass memory b = MessageLib.deserializeNotifyShareClass(a.serialize());

        string calldata slicedName = bytes(name).length > 128 ? name[0:128] : name;

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(slicedName, b.name);
        assertEq(a.symbol, b.symbol);
        assertEq(a.decimals, b.decimals);
        assertEq(a.salt, b.salt);
        assertEq(a.registrar, b.registrar);
        assertEq(a.extraGasLimit, b.extraGasLimit);
        assertEq(a.payload, b.payload);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), extraGasLimit);

        // Check the payload length is correctly encoded as a 2-byte big-endian prefix ahead of the payload
        bytes memory serialized = a.serialize();
        uint256 lengthIndex = serialized.messageLength() - a.payload.length - 2;
        assertEq((uint256(uint8(serialized[lengthIndex])) << 8) | uint8(serialized[lengthIndex + 1]), a.payload.length);
    }

    function testNotifyPricePoolPerShare(uint64 poolId, bytes16 scId, uint128 price, uint64 timestamp) public pure {
        MessageLib.NotifyPricePoolPerShare memory a =
            MessageLib.NotifyPricePoolPerShare({poolId: poolId, scId: scId, price: price, timestamp: timestamp});
        MessageLib.NotifyPricePoolPerShare memory b = MessageLib.deserializeNotifyPricePoolPerShare(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.price, b.price);
        assertEq(a.timestamp, b.timestamp);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messageExtraGasLimit(), 0);
    }

    function testNotifyPricePoolPerAsset(uint64 poolId, bytes16 scId, uint128 assetId, uint128 price, uint64 timestamp)
        public
        pure
    {
        MessageLib.NotifyPricePoolPerAsset memory a = MessageLib.NotifyPricePoolPerAsset({
            poolId: poolId, scId: scId, assetId: assetId, price: price, timestamp: timestamp
        });
        MessageLib.NotifyPricePoolPerAsset memory b = MessageLib.deserializeNotifyPricePoolPerAsset(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.price, b.price);
        assertEq(a.timestamp, b.timestamp);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), 0);
    }

    function testNotifyShareMetadata(
        uint64 poolId,
        bytes16 scId,
        string calldata name,
        bytes32 symbol,
        uint128 extraGasLimit
    ) public pure {
        MessageLib.NotifyShareMetadata memory a = MessageLib.NotifyShareMetadata({
            poolId: poolId, scId: scId, name: name, symbol: symbol, extraGasLimit: extraGasLimit
        });
        MessageLib.NotifyShareMetadata memory b = MessageLib.deserializeNotifyShareMetadata(a.serialize());

        string calldata slicedName = bytes(name).length > 128 ? name[0:128] : name;

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(slicedName, b.name);
        assertEq(a.symbol, b.symbol);
        assertEq(a.extraGasLimit, b.extraGasLimit);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), extraGasLimit);
    }

    function testInitiateTransferShares(
        uint64 poolId,
        bytes16 scId,
        uint16 centrifugeId,
        bytes32 receiver,
        uint128 amount,
        uint128 remoteExtraGasLimit,
        uint128 extraGasLimit,
        bytes32 sender
    ) public pure {
        MessageLib.InitiateTransferShares memory a = MessageLib.InitiateTransferShares({
            poolId: poolId,
            scId: scId,
            centrifugeId: centrifugeId,
            receiver: receiver,
            amount: amount,
            remoteExtraGasLimit: remoteExtraGasLimit,
            extraGasLimit: extraGasLimit,
            sender: sender
        });
        MessageLib.InitiateTransferShares memory b = MessageLib.deserializeInitiateTransferShares(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.centrifugeId, b.centrifugeId);
        assertEq(a.receiver, b.receiver);
        assertEq(a.amount, b.amount);
        assertEq(a.sender, b.sender);
        assertEq(a.remoteExtraGasLimit, b.remoteExtraGasLimit);
        assertEq(a.extraGasLimit, b.extraGasLimit);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), a.extraGasLimit);
    }

    function testExecuteTransferShares(
        uint64 poolId,
        bytes16 scId,
        bytes32 receiver,
        uint128 amount,
        uint128 extraGasLimit
    ) public pure {
        MessageLib.ExecuteTransferShares memory a = MessageLib.ExecuteTransferShares({
            poolId: poolId, scId: scId, receiver: receiver, amount: amount, extraGasLimit: extraGasLimit
        });
        MessageLib.ExecuteTransferShares memory b = MessageLib.deserializeExecuteTransferShares(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.receiver, b.receiver);
        assertEq(a.amount, b.amount);
        assertEq(a.extraGasLimit, b.extraGasLimit);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), a.extraGasLimit);
    }

    function testUpdateRestriction(uint64 poolId, bytes16 scId, uint128 extraGasLimit, bytes memory payload)
        public
        pure
    {
        MessageLib.UpdateRestriction memory a = MessageLib.UpdateRestriction({
            poolId: poolId, scId: scId, extraGasLimit: extraGasLimit, payload: payload
        });
        MessageLib.UpdateRestriction memory b = MessageLib.deserializeUpdateRestriction(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.extraGasLimit, b.extraGasLimit);
        assertEq(a.payload, b.payload);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), a.extraGasLimit);

        // Check the payload length is correctly encoded as a 2-byte big-endian prefix ahead of the payload
        bytes memory serialized = a.serialize();
        uint256 lengthIndex = serialized.messageLength() - a.payload.length - 2;
        assertEq((uint256(uint8(serialized[lengthIndex])) << 8) | uint8(serialized[lengthIndex + 1]), a.payload.length);
    }

    function testManagerCall(uint64 poolId, bytes32 target, uint128 extraGasLimit, bytes memory payload) public pure {
        MessageLib.ManagerCallFromHub memory a = MessageLib.ManagerCallFromHub({
            poolId: poolId, target: target, extraGasLimit: extraGasLimit, payload: payload
        });
        MessageLib.ManagerCallFromHub memory b = MessageLib.deserializeManagerCallFromHub(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.target, b.target);
        assertEq(a.extraGasLimit, b.extraGasLimit);
        assertEq(a.payload, b.payload);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), a.extraGasLimit);

        // Check the payload length is correctly encoded as a 2-byte big-endian prefix ahead of the payload
        bytes memory serialized = a.serialize();
        uint256 lengthIndex = serialized.messageLength() - a.payload.length - 2;
        assertEq((uint256(uint8(serialized[lengthIndex])) << 8) | uint8(serialized[lengthIndex + 1]), a.payload.length);
    }

    function testRequest(uint64 poolId, bytes16 scId, uint128 assetId, uint128 extraGasLimit, bytes memory payload)
        public
        pure
    {
        MessageLib.Request memory a = MessageLib.Request({
            poolId: poolId, scId: scId, assetId: assetId, extraGasLimit: extraGasLimit, payload: payload
        });
        MessageLib.Request memory b = MessageLib.deserializeRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.extraGasLimit, b.extraGasLimit);
        assertEq(a.payload, b.payload);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), a.extraGasLimit);

        // Check the payload length is correctly encoded as a 2-byte big-endian prefix ahead of the payload
        bytes memory serialized = a.serialize();
        uint256 lengthIndex = serialized.messageLength() - a.payload.length - 2;
        assertEq((uint256(uint8(serialized[lengthIndex])) << 8) | uint8(serialized[lengthIndex + 1]), a.payload.length);
    }

    function testRequestCallback(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        uint128 extraGasLimit,
        bytes memory payload
    ) public pure {
        MessageLib.RequestCallback memory a = MessageLib.RequestCallback({
            poolId: poolId, scId: scId, assetId: assetId, extraGasLimit: extraGasLimit, payload: payload
        });
        MessageLib.RequestCallback memory b = MessageLib.deserializeRequestCallback(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.extraGasLimit, b.extraGasLimit);
        assertEq(a.payload, b.payload);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), a.extraGasLimit);

        // Check the payload length is correctly encoded as a 2-byte big-endian prefix ahead of the payload
        bytes memory serialized = a.serialize();
        uint256 lengthIndex = serialized.messageLength() - a.payload.length - 2;
        assertEq((uint256(uint8(serialized[lengthIndex])) << 8) | uint8(serialized[lengthIndex + 1]), a.payload.length);
    }

    function testUpdateVault(
        uint64 poolId,
        bytes16 scId,
        bytes32 vaultOrFactory,
        uint128 assetId,
        uint8 kind,
        uint128 extraGasLimit,
        bytes memory payload
    ) public pure {
        MessageLib.UpdateVault memory a = MessageLib.UpdateVault({
            poolId: poolId,
            scId: scId,
            assetId: assetId,
            vaultOrFactory: vaultOrFactory,
            kind: kind,
            extraGasLimit: extraGasLimit,
            payload: payload
        });
        MessageLib.UpdateVault memory b = MessageLib.deserializeUpdateVault(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.vaultOrFactory, b.vaultOrFactory);
        assertEq(a.kind, b.kind);
        assertEq(a.extraGasLimit, b.extraGasLimit);
        assertEq(a.payload, b.payload);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), a.extraGasLimit);

        // Check the payload length is correctly encoded as a 2-byte big-endian prefix ahead of the payload
        bytes memory serialized = a.serialize();
        uint256 lengthIndex = serialized.messageLength() - a.payload.length - 2;
        assertEq((uint256(uint8(serialized[lengthIndex])) << 8) | uint8(serialized[lengthIndex + 1]), a.payload.length);
    }

    function testSetRequestManager(uint64 poolId, bytes32 manager) public pure {
        MessageLib.SetRequestManager memory a = MessageLib.SetRequestManager({poolId: poolId, manager: manager});
        MessageLib.SetRequestManager memory b = MessageLib.deserializeSetRequestManager(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.manager, b.manager);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), 0);
    }

    function testSetPolicy(uint64 poolId, bytes32 policy) public pure {
        MessageLib.SetPolicy memory a = MessageLib.SetPolicy({poolId: poolId, policy: policy});
        MessageLib.SetPolicy memory b = MessageLib.deserializeSetPolicy(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.policy, b.policy);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), 0);
    }

    function testAuthorize(uint64 poolId, bytes memory data) public pure {
        MessageLib.AuthorizeSpokeCall memory a = MessageLib.AuthorizeSpokeCall({poolId: poolId, payload: data});
        MessageLib.AuthorizeSpokeCall memory b = MessageLib.deserializeAuthorizeSpokeCall(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.payload, b.payload);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), 0);
    }

    function testUnauthorize(uint64 poolId, bytes memory data) public pure {
        MessageLib.UnauthorizeSpokeCall memory a = MessageLib.UnauthorizeSpokeCall({poolId: poolId, payload: data});
        MessageLib.UnauthorizeSpokeCall memory b = MessageLib.deserializeUnauthorizeSpokeCall(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.payload, b.payload);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), 0);
    }

    function testUpdateManager(uint64 poolId, uint8 kind, bytes32 who, bool canManage) public pure {
        MessageLib.UpdateManager memory a =
            MessageLib.UpdateManager({poolId: poolId, kind: kind, who: who, canManage: canManage});
        MessageLib.UpdateManager memory b = MessageLib.deserializeUpdateManager(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.kind, b.kind);
        assertEq(a.who, b.who);
        assertEq(a.canManage, b.canManage);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), 0);
    }

    function testUpdateHoldingAmount(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        uint128 amount,
        uint64 timestamp,
        bool isIncrease,
        bool isSnapshot,
        uint64 nonce,
        uint128 extraGasLimit
    ) public pure {
        MessageLib.UpdateAssets memory a = MessageLib.UpdateAssets({
            poolId: poolId,
            scId: scId,
            assetId: assetId,
            amount: amount,
            timestamp: timestamp,
            isIncrease: isIncrease,
            isSnapshot: isSnapshot,
            nonce: nonce,
            extraGasLimit: extraGasLimit
        });

        MessageLib.UpdateAssets memory b = MessageLib.deserializeUpdateAssets(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.amount, b.amount);
        assertEq(a.timestamp, b.timestamp);
        assertEq(a.isIncrease, b.isIncrease);
        assertEq(a.isSnapshot, b.isSnapshot);
        assertEq(a.nonce, b.nonce);
        assertEq(a.extraGasLimit, b.extraGasLimit);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), a.extraGasLimit);
    }

    function testUpdateShares(
        uint64 poolId,
        bytes16 scId,
        uint128 shares,
        uint64 timestamp,
        bool isIssuance,
        bool isSnapshot,
        uint64 nonce,
        uint128 extraGasLimit
    ) public pure {
        MessageLib.UpdateShares memory a = MessageLib.UpdateShares({
            poolId: poolId,
            scId: scId,
            shares: shares,
            timestamp: timestamp,
            isIssuance: isIssuance,
            isSnapshot: isSnapshot,
            nonce: nonce,
            extraGasLimit: extraGasLimit
        });

        MessageLib.UpdateShares memory b = MessageLib.deserializeUpdateShares(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.shares, b.shares);
        assertEq(a.timestamp, b.timestamp);
        assertEq(a.isIssuance, b.isIssuance);
        assertEq(a.isSnapshot, b.isSnapshot);
        assertEq(a.nonce, b.nonce);
        assertEq(a.extraGasLimit, b.extraGasLimit);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), a.extraGasLimit);
    }

    function testManagerCallFromSpoke(
        uint64 poolId,
        bytes32 target,
        bytes32 sender,
        uint128 extraGasLimit,
        bytes memory payload
    ) public pure {
        MessageLib.ManagerCallFromSpoke memory a = MessageLib.ManagerCallFromSpoke({
            poolId: poolId, target: target, sender: sender, extraGasLimit: extraGasLimit, payload: payload
        });
        MessageLib.ManagerCallFromSpoke memory b = MessageLib.deserializeManagerCallFromSpoke(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.target, b.target);
        assertEq(a.payload, b.payload);
        assertEq(a.sender, b.sender);
        assertEq(a.extraGasLimit, b.extraGasLimit);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageExtraGasLimit(), a.extraGasLimit);
    }
}

contract TestMessageLibSourceCentrifugeId is Test {
    /// @dev Exhaustive, hand-maintained expectation for every MessageType, cross-checking
    ///      MessageLib.messageSourceCentrifugeId. If a new message type is added, this test fails
    ///      until it is classified here, surfacing any spoke->hub message that would otherwise be
    ///      incorrectly rejected when arriving from its source chain.
    ///
    ///      The test buffer encodes centrifugeId=1 at the two positions read by the function:
    ///        buf[2]  = 0x01 → poolId at offset 1 has centrifugeId=1 (uint64, top 16 bits)
    ///                       → assetId at offset 1 has centrifugeId=1 (uint128, top 16 bits)
    ///        buf[26] = 0x01 → assetId at offset 25 has centrifugeId=1
    function testMessageSourceCentrifugeIdForEveryMessageType() public pure {
        uint256 max = uint256(type(MessageType).max);

        bytes memory buf = new bytes(50);
        buf[2] = bytes1(uint8(1)); // centrifugeId=1 for poolId@1 and assetId@1
        buf[26] = bytes1(uint8(1)); // centrifugeId=1 for assetId@25

        uint16[] memory expected = new uint16[](max + 1);

        // Hub->spoke: must originate from the pool's home chain (centrifugeId=1 via buf[2]).
        expected[uint256(MessageType.SetPoolAdapters)] = 1;
        expected[uint256(MessageType.NotifyPool)] = 1;
        expected[uint256(MessageType.NotifyShareClass)] = 1;
        expected[uint256(MessageType.NotifyPricePoolPerShare)] = 1;
        expected[uint256(MessageType.NotifyPricePoolPerAsset)] = 1;
        expected[uint256(MessageType.NotifyShareMetadata)] = 1;
        expected[uint256(MessageType.ExecuteTransferShares)] = 1;
        expected[uint256(MessageType.UpdateRestriction)] = 1;
        expected[uint256(MessageType.UpdateVault)] = 1;
        expected[uint256(MessageType.RequestCallback)] = 1;
        expected[uint256(MessageType.SetRequestManager)] = 1;
        expected[uint256(MessageType.UpdateManager)] = 1;
        expected[uint256(MessageType.ManagerCallFromHub)] = 1;
        expected[uint256(MessageType.SetPolicy)] = 1;
        expected[uint256(MessageType.AuthorizeSpokeCall)] = 1;
        expected[uint256(MessageType.UnauthorizeSpokeCall)] = 1;

        // Mainnet-only messages (centrifugeId=MAINNET_CENTRIFUGE_ID=1).
        expected[uint256(MessageType.ScheduleUpgrade)] = 1;
        expected[uint256(MessageType.CancelUpgrade)] = 1;

        // Asset-homed messages (centrifugeId=1 from the encoded assetId).
        expected[uint256(MessageType.RegisterAsset)] = 1; // assetId at offset 1
        expected[uint256(MessageType.Request)] = 1; // assetId at offset 25
        expected[uint256(MessageType.UpdateAssets)] = 1; // assetId at offset 25

        // Unrestricted spoke->hub messages (0 = any source permitted).
        expected[uint256(MessageType.InitiateTransferShares)] = 0;
        expected[uint256(MessageType.UpdateShares)] = 0;
        expected[uint256(MessageType.ManagerCallFromSpoke)] = 0;

        // _Invalid has no source restriction.
        expected[uint256(MessageType._Invalid)] = 0;

        for (uint256 i = 0; i <= max; i++) {
            buf[0] = bytes1(uint8(i));
            assertEq(
                MessageLib.messageSourceCentrifugeId(buf),
                expected[i],
                "unexpected messageSourceCentrifugeId classification"
            );
        }
    }

    /// @dev A hub->spoke message whose poolId encodes centrifugeId=0 is always forged (no real pool has
    ///      centrifugeId 0) and must revert rather than fall through to the "0 = any source" sentinel.
    /// forge-config: default.allow_internal_expect_revert = true
    function testMessageSourceCentrifugeIdRevertsOnZeroPoolHome() public {
        bytes memory buf = new bytes(50);
        buf[0] = bytes1(uint8(MessageType.NotifyPool));
        // buf[2] left as 0 => poolId's centrifugeId resolves to 0.

        vm.expectRevert(MessageLib.InvalidPoolHome.selector);
        MessageLib.messageSourceCentrifugeId(buf);
    }

    /// @dev An asset-homed message (RegisterAsset/Request/UpdateAssets) whose assetId encodes
    ///      centrifugeId=0 is an ISO-4217 currency asset, which is never legitimately reported by a
    ///      spoke, and must revert rather than fall through to the "0 = any source" sentinel.
    /// forge-config: default.allow_internal_expect_revert = true
    function testMessageSourceCentrifugeIdRevertsOnZeroAssetHome() public {
        MessageType[3] memory kinds = [MessageType.RegisterAsset, MessageType.Request, MessageType.UpdateAssets];

        for (uint256 i = 0; i < kinds.length; i++) {
            bytes memory buf = new bytes(50);
            buf[0] = bytes1(uint8(kinds[i]));
            // assetId's centrifugeId (offset 1 for RegisterAsset, offset 25 for Request/UpdateAssets)
            // is left as 0, encoding an ISO-currency asset.

            vm.expectRevert(MessageLib.InvalidAssetHome.selector);
            MessageLib.messageSourceCentrifugeId(buf);
        }
    }
}

contract TestMessageLibUpdateVaultFraming is Test {
    using MessageLib for *;
    using BytesLib for bytes;

    uint64 constant POOL_ID = (uint64(1) << 48) | 7;

    function _updateVault(VaultUpdateKind kind, bytes memory payload) internal pure returns (bytes memory) {
        return MessageLib.UpdateVault({
                poolId: POOL_ID,
                scId: bytes16(uint128(2)),
                assetId: 3,
                vaultOrFactory: bytes32(uint256(4)),
                kind: uint8(kind),
                extraGasLimit: 5,
                payload: payload
            }).serialize();
    }

    function _payload(uint256 len) internal pure returns (bytes memory payload) {
        payload = new bytes(len);
        for (uint256 i; i < len; i++) {
            payload[i] = bytes1(uint8(i));
        }
    }

    /// @dev Above 255 bytes the length prefix's high byte is non-zero, so a low-byte-only walk desyncs the batch
    function testBatchWalkResynchronizesAfterLargePayload() public pure {
        bytes memory first = _updateVault(VaultUpdateKind.DeployAndLink, _payload(300));
        bytes memory second = _updateVault(VaultUpdateKind.Unlink, "");

        // Gateway rejects a batch whose messages disagree on the pool, so the walk is only reachable if they match.
        assertEq(first.messagePoolId().raw(), second.messagePoolId().raw());

        bytes memory remaining = abi.encodePacked(first, second);

        uint256 firstLength = remaining.messageLength();
        assertEq(firstLength, first.length);
        bytes memory walkedFirst = remaining.slice(0, firstLength);
        assertEq(walkedFirst, first);
        assertEq(MessageLib.deserializeUpdateVault(walkedFirst).payload, _payload(300));

        remaining = remaining.slice(firstLength, remaining.length - firstLength);

        uint256 secondLength = remaining.messageLength();
        assertEq(secondLength, second.length);
        assertEq(remaining.slice(0, secondLength), second);

        remaining = remaining.slice(secondLength, remaining.length - secondLength);
        assertEq(remaining.length, 0);
    }

    /// @dev Legacy spokes resume at the length-prefix byte as a type; MESSAGE_MAX_LENGTH < 256 * NotifyPool blocks that
    function testMessageMaxLengthCannotReachPoolDependentTypes() public pure {
        uint256 header = _updateVault(VaultUpdateKind.Link, "").length;
        assertEq(header, 92, "fixed fields plus the 2-byte length prefix");

        assertLt(MESSAGE_MAX_LENGTH, header + 256 * uint256(uint8(MessageType.NotifyPool)));
    }
}
