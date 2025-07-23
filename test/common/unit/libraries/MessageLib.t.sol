// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../../src/common/types/AssetId.sol";
import {MessageProofLib} from "../../../../src/common/libraries/MessageProofLib.sol";
import {MessageType, MessageLib} from "../../../../src/common/libraries/MessageLib.sol";

import "forge-std/Test.sol";

contract TestMessageProofCompatibility is Test {
    function testMessageProofCompatibility() public pure {
        assertNotEq(uint8(type(MessageType).max), MessageProofLib.MESSAGE_PROOF_ID);
    }
}

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
    function testDeserializeRecoverTokens() public {
        MessageLib.deserializeRecoverTokens(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeRegisterAsset() public {
        MessageLib.deserializeRegisterAsset(_prepareFor());
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
    function testDeserializeNotifyShareHook() public {
        MessageLib.deserializeUpdateShareHook(_prepareFor());
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
    function testDeserializeUpdateContract() public {
        MessageLib.deserializeUpdateContract(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeUpdateVault() public {
        MessageLib.deserializeUpdateVault(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeUpdateBalanceSheetManager() public {
        MessageLib.deserializeUpdateBalanceSheetManager(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeUpdateHoldingAmount() public {
        MessageLib.deserializeUpdateHoldingAmount(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeUpdateShares() public {
        MessageLib.deserializeUpdateShares(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeMaxAssetPriceAge() public {
        MessageLib.deserializeMaxAssetPriceAge(_prepareFor());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeMaxSharePriceAge() public {
        MessageLib.deserializeMaxSharePriceAge(_prepareFor());
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
    function testMessageLength() public {
        bytes memory buffer = new bytes(1);
        buffer[0] = bytes1(uint8(type(MessageType).max) + 1);
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
        assertEq(a.serialize().messageSourceCentrifugeId(), 0);
    }

    function testCancelUpgrade(bytes32 target) public pure {
        MessageLib.CancelUpgrade memory a = MessageLib.CancelUpgrade({target: target});
        MessageLib.CancelUpgrade memory b = MessageLib.deserializeCancelUpgrade(a.serialize());

        assertEq(a.target, b.target);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messageSourceCentrifugeId(), 0);
    }

    function testRecoverTokens(bytes32 target, bytes32 token, uint256 tokenId, bytes32 to, uint256 amount)
        public
        pure
    {
        MessageLib.RecoverTokens memory a =
            MessageLib.RecoverTokens({target: target, token: token, tokenId: tokenId, to: to, amount: amount});
        MessageLib.RecoverTokens memory b = MessageLib.deserializeRecoverTokens(a.serialize());

        assertEq(a.target, b.target);
        assertEq(a.token, b.token);
        assertEq(a.tokenId, b.tokenId);
        assertEq(a.to, b.to);
        assertEq(a.amount, b.amount);

        assertEq(a.serialize().messageLength(), a.serialize().length, "XXX");
        assertEq(a.serialize().messageSourceCentrifugeId(), 0);
    }

    function testRegisterAsset(uint128 assetId, uint8 decimals) public pure {
        MessageLib.RegisterAsset memory a = MessageLib.RegisterAsset({assetId: assetId, decimals: decimals});
        MessageLib.RegisterAsset memory b = MessageLib.deserializeRegisterAsset(a.serialize());

        assertEq(a.assetId, b.assetId);
        assertEq(a.decimals, b.decimals);

        assertEq(bytes(a.serialize()).length, a.serialize().messageLength());
        assertEq(a.serialize().messageSourceCentrifugeId(), AssetId.wrap(assetId).centrifugeId());
    }

    function testNotifyPool(uint64 poolId) public pure {
        MessageLib.NotifyPool memory a = MessageLib.NotifyPool({poolId: poolId});
        MessageLib.NotifyPool memory b = MessageLib.deserializeNotifyPool(a.serialize());

        assertEq(a.poolId, b.poolId);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
    }

    function testNotifyShareClass(
        uint64 poolId,
        bytes16 scId,
        string calldata name,
        bytes32 symbol,
        uint8 decimals,
        bytes32 salt,
        bytes32 hook
    ) public pure {
        MessageLib.NotifyShareClass memory a = MessageLib.NotifyShareClass({
            poolId: poolId,
            scId: scId,
            name: name,
            symbol: symbol,
            decimals: decimals,
            salt: salt,
            hook: hook
        });
        MessageLib.NotifyShareClass memory b = MessageLib.deserializeNotifyShareClass(a.serialize());

        string calldata slicedName = bytes(name).length > 128 ? name[0:128] : name;

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(slicedName, b.name);
        assertEq(a.symbol, b.symbol);
        assertEq(a.decimals, b.decimals);
        assertEq(a.salt, b.salt);
        assertEq(a.hook, b.hook);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
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
        assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
    }

    function testNotifyPricePoolPerAsset(uint64 poolId, bytes16 scId, uint128 assetId, uint128 price, uint64 timestamp)
        public
        pure
    {
        MessageLib.NotifyPricePoolPerAsset memory a = MessageLib.NotifyPricePoolPerAsset({
            poolId: poolId,
            scId: scId,
            assetId: assetId,
            price: price,
            timestamp: timestamp
        });
        MessageLib.NotifyPricePoolPerAsset memory b = MessageLib.deserializeNotifyPricePoolPerAsset(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.price, b.price);
        assertEq(a.timestamp, b.timestamp);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
    }

    function testNotifyShareMetadata(uint64 poolId, bytes16 scId, string calldata name, bytes32 symbol) public pure {
        MessageLib.NotifyShareMetadata memory a =
            MessageLib.NotifyShareMetadata({poolId: poolId, scId: scId, name: name, symbol: symbol});
        MessageLib.NotifyShareMetadata memory b = MessageLib.deserializeNotifyShareMetadata(a.serialize());

        string calldata slicedName = bytes(name).length > 128 ? name[0:128] : name;

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(slicedName, b.name);
        assertEq(a.symbol, b.symbol);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
    }

    function testUpdateShareHook(uint64 poolId, bytes16 scId, bytes32 hook) public pure {
        MessageLib.UpdateShareHook memory a = MessageLib.UpdateShareHook({poolId: poolId, scId: scId, hook: hook});
        MessageLib.UpdateShareHook memory b = MessageLib.deserializeUpdateShareHook(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.hook, b.hook);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
    }

    function testInitiateTransferShares(
        uint64 poolId,
        bytes16 scId,
        uint16 centrifugeId,
        bytes32 receiver,
        uint128 amount,
        uint128 extraGasLimit
    ) public pure {
        MessageLib.InitiateTransferShares memory a = MessageLib.InitiateTransferShares({
            poolId: poolId,
            scId: scId,
            centrifugeId: centrifugeId,
            receiver: receiver,
            amount: amount,
            extraGasLimit: extraGasLimit
        });
        MessageLib.InitiateTransferShares memory b = MessageLib.deserializeInitiateTransferShares(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.centrifugeId, b.centrifugeId);
        assertEq(a.receiver, b.receiver);
        assertEq(a.amount, b.amount);
        assertEq(a.extraGasLimit, b.extraGasLimit);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), 0);
    }

    function testExecuteTransferShares(uint64 poolId, bytes16 scId, bytes32 receiver, uint128 amount) public pure {
        MessageLib.ExecuteTransferShares memory a =
            MessageLib.ExecuteTransferShares({poolId: poolId, scId: scId, receiver: receiver, amount: amount});
        MessageLib.ExecuteTransferShares memory b = MessageLib.deserializeExecuteTransferShares(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.receiver, b.receiver);
        assertEq(a.amount, b.amount);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
    }

    function testUpdateRestriction(uint64 poolId, bytes16 scId, bytes memory payload) public pure {
        MessageLib.UpdateRestriction memory a =
            MessageLib.UpdateRestriction({poolId: poolId, scId: scId, payload: payload});
        MessageLib.UpdateRestriction memory b = MessageLib.deserializeUpdateRestriction(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.payload, b.payload);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());

        // Check the payload length is correctly encoded as little endian
        assertEq(a.payload.length, uint8(a.serialize()[a.serialize().messageLength() - a.payload.length - 1]));
    }

    function testUpdateContract(uint64 poolId, bytes16 scId, bytes32 target, bytes memory payload) public pure {
        MessageLib.UpdateContract memory a =
            MessageLib.UpdateContract({poolId: poolId, scId: scId, target: target, payload: payload});
        MessageLib.UpdateContract memory b = MessageLib.deserializeUpdateContract(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.target, b.target);
        assertEq(a.payload, b.payload);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());

        // Check the payload length is correctly encoded as little endian
        assertEq(a.payload.length, uint8(a.serialize()[a.serialize().messageLength() - a.payload.length - 1]));
    }

    function testRequest(uint64 poolId, bytes16 scId, uint128 assetId, bytes memory payload) public pure {
        MessageLib.Request memory a =
            MessageLib.Request({poolId: poolId, scId: scId, assetId: assetId, payload: payload});
        MessageLib.Request memory b = MessageLib.deserializeRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.payload, b.payload);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), AssetId.wrap(assetId).centrifugeId());

        // Check the payload length is correctly encoded as little endian
        assertEq(a.payload.length, uint8(a.serialize()[a.serialize().messageLength() - a.payload.length - 1]));
    }

    function testRequestCallback(uint64 poolId, bytes16 scId, uint128 assetId, bytes memory payload) public pure {
        MessageLib.RequestCallback memory a =
            MessageLib.RequestCallback({poolId: poolId, scId: scId, assetId: assetId, payload: payload});
        MessageLib.RequestCallback memory b = MessageLib.deserializeRequestCallback(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.payload, b.payload);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());

        // Check the payload length is correctly encoded as little endian
        assertEq(a.payload.length, uint8(a.serialize()[a.serialize().messageLength() - a.payload.length - 1]));
    }

    function testUpdateVault(uint64 poolId, bytes16 scId, bytes32 vaultOrFactory, uint128 assetId, uint8 kind)
        public
        pure
    {
        MessageLib.UpdateVault memory a = MessageLib.UpdateVault({
            poolId: poolId,
            scId: scId,
            assetId: assetId,
            vaultOrFactory: vaultOrFactory,
            kind: kind
        });
        MessageLib.UpdateVault memory b = MessageLib.deserializeUpdateVault(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.vaultOrFactory, b.vaultOrFactory);
        assertEq(a.kind, b.kind);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
    }

    function testSetRequestManager(uint64 poolId, bytes16 scId, uint128 assetId, bytes32 manager) public pure {
        MessageLib.SetRequestManager memory a =
            MessageLib.SetRequestManager({poolId: poolId, scId: scId, assetId: assetId, manager: manager});
        MessageLib.SetRequestManager memory b = MessageLib.deserializeSetRequestManager(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.manager, b.manager);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
    }

    function testUpdateBalanceSheetManager(uint64 poolId, bytes32 who, bool canManage) public pure {
        MessageLib.UpdateBalanceSheetManager memory a =
            MessageLib.UpdateBalanceSheetManager({poolId: poolId, who: who, canManage: canManage});
        MessageLib.UpdateBalanceSheetManager memory b = MessageLib.deserializeUpdateBalanceSheetManager(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.who, b.who);
        assertEq(a.canManage, b.canManage);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
    }

    // function testDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
    //     public
    //     pure
    // {
    //     MessageLib.DepositRequest memory a = MessageLib.DepositRequest({
    //         poolId: poolId,
    //         scId: scId,
    //         investor: investor,
    //         assetId: assetId,
    //         amount: amount
    //     });
    //     MessageLib.DepositRequest memory b = MessageLib.deserializeDepositRequest(a.serialize());

    //     assertEq(a.poolId, b.poolId);
    //     assertEq(a.scId, b.scId);
    //     assertEq(a.investor, b.investor);
    //     assertEq(a.assetId, b.assetId);
    //     assertEq(a.amount, b.amount);

    //     assertEq(a.serialize().messageLength(), a.serialize().length);
    //     assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    //     assertEq(a.serialize().messageSourceCentrifugeId(), AssetId.wrap(assetId).centrifugeId());
    // }

    // function testRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
    //     public
    //     pure
    // {
    //     MessageLib.RedeemRequest memory a =
    //         MessageLib.RedeemRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId, amount:
    // amount});
    //     MessageLib.RedeemRequest memory b = MessageLib.deserializeRedeemRequest(a.serialize());

    //     assertEq(a.poolId, b.poolId);
    //     assertEq(a.scId, b.scId);
    //     assertEq(a.investor, b.investor);
    //     assertEq(a.assetId, b.assetId);
    //     assertEq(a.amount, b.amount);

    //     assertEq(a.serialize().messageLength(), a.serialize().length);
    //     assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    //     assertEq(a.serialize().messageSourceCentrifugeId(), AssetId.wrap(assetId).centrifugeId());
    // }

    // function testCancelDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) public pure {
    //     MessageLib.CancelDepositRequest memory a =
    //         MessageLib.CancelDepositRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId});
    //     MessageLib.CancelDepositRequest memory b = MessageLib.deserializeCancelDepositRequest(a.serialize());

    //     assertEq(a.poolId, b.poolId);
    //     assertEq(a.scId, b.scId);
    //     assertEq(a.investor, b.investor);
    //     assertEq(a.assetId, b.assetId);

    //     assertEq(a.serialize().messageLength(), a.serialize().length);
    //     assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    //     assertEq(a.serialize().messageSourceCentrifugeId(), AssetId.wrap(assetId).centrifugeId());
    // }

    // function testCancelRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) public pure {
    //     MessageLib.CancelRedeemRequest memory a =
    //         MessageLib.CancelRedeemRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId});
    //     MessageLib.CancelRedeemRequest memory b = MessageLib.deserializeCancelRedeemRequest(a.serialize());

    //     assertEq(a.poolId, b.poolId);
    //     assertEq(a.scId, b.scId);
    //     assertEq(a.investor, b.investor);
    //     assertEq(a.assetId, b.assetId);

    //     assertEq(a.serialize().messageLength(), a.serialize().length);
    //     assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    //     assertEq(a.serialize().messageSourceCentrifugeId(), AssetId.wrap(assetId).centrifugeId());
    // }

    // function testFulfilledDepositRequest(
    //     uint64 poolId,
    //     bytes16 scId,
    //     bytes32 investor,
    //     uint128 assetId,
    //     uint128 fulfilledAssetAmount,
    //     uint128 fulfilledShareAmount,
    //     uint128 cancelledAssetAmount
    // ) public pure {
    //     MessageLib.FulfilledDepositRequest memory a = MessageLib.FulfilledDepositRequest({
    //         poolId: poolId,
    //         scId: scId,
    //         investor: investor,
    //         assetId: assetId,
    //         fulfilledAssetAmount: fulfilledAssetAmount,
    //         fulfilledShareAmount: fulfilledShareAmount,
    //         cancelledAssetAmount: cancelledAssetAmount
    //     });
    //     MessageLib.FulfilledDepositRequest memory b = MessageLib.deserializeFulfilledDepositRequest(a.serialize());

    //     assertEq(a.poolId, b.poolId);
    //     assertEq(a.scId, b.scId);
    //     assertEq(a.investor, b.investor);
    //     assertEq(a.assetId, b.assetId);
    //     assertEq(a.fulfilledAssetAmount, b.fulfilledAssetAmount);
    //     assertEq(a.fulfilledShareAmount, b.fulfilledShareAmount);
    //     assertEq(a.cancelledAssetAmount, b.cancelledAssetAmount);

    //     assertEq(a.serialize().messageLength(), a.serialize().length);
    //     assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    //     assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
    // }

    // function testFulfilledRedeemRequest(
    //     uint64 poolId,
    //     bytes16 scId,
    //     bytes32 investor,
    //     uint128 assetId,
    //     uint128 fulfilledAssetAmount,
    //     uint128 fulfilledShareAmount,
    //     uint128 cancelledShareAmount
    // ) public pure {
    //     MessageLib.FulfilledRedeemRequest memory a = MessageLib.FulfilledRedeemRequest({
    //         poolId: poolId,
    //         scId: scId,
    //         investor: investor,
    //         assetId: assetId,
    //         fulfilledAssetAmount: fulfilledAssetAmount,
    //         fulfilledShareAmount: fulfilledShareAmount,
    //         cancelledShareAmount: cancelledShareAmount
    //     });
    //     MessageLib.FulfilledRedeemRequest memory b = MessageLib.deserializeFulfilledRedeemRequest(a.serialize());

    //     assertEq(a.poolId, b.poolId);
    //     assertEq(a.scId, b.scId);
    //     assertEq(a.investor, b.investor);
    //     assertEq(a.assetId, b.assetId);
    //     assertEq(a.fulfilledAssetAmount, b.fulfilledAssetAmount);
    //     assertEq(a.fulfilledShareAmount, b.fulfilledShareAmount);
    //     assertEq(a.cancelledShareAmount, b.cancelledShareAmount);

    //     assertEq(a.serialize().messageLength(), a.serialize().length);
    //     assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    //     assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
    // }

    function testUpdateHoldingAmount(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        uint128 amount,
        uint128 pricePerUnit,
        uint64 timestamp,
        bool isIncrease,
        bool isSnapshot,
        uint64 nonce
    ) public pure {
        MessageLib.UpdateHoldingAmount memory a = MessageLib.UpdateHoldingAmount({
            poolId: poolId,
            scId: scId,
            assetId: assetId,
            amount: amount,
            pricePerUnit: pricePerUnit,
            timestamp: timestamp,
            isIncrease: isIncrease,
            isSnapshot: isSnapshot,
            nonce: nonce
        });

        MessageLib.UpdateHoldingAmount memory b = MessageLib.deserializeUpdateHoldingAmount(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.amount, b.amount);
        assertEq(a.pricePerUnit, b.pricePerUnit);
        assertEq(a.timestamp, b.timestamp);
        assertEq(a.isIncrease, b.isIncrease);
        assertEq(a.isSnapshot, b.isSnapshot);
        assertEq(a.nonce, b.nonce);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), AssetId.wrap(assetId).centrifugeId());
    }

    function testUpdateShares(
        uint64 poolId,
        bytes16 scId,
        uint128 shares,
        uint64 timestamp,
        bool isIssuance,
        bool isSnapshot,
        uint64 nonce
    ) public pure {
        MessageLib.UpdateShares memory a = MessageLib.UpdateShares({
            poolId: poolId,
            scId: scId,
            shares: shares,
            timestamp: timestamp,
            isIssuance: isIssuance,
            isSnapshot: isSnapshot,
            nonce: nonce
        });

        MessageLib.UpdateShares memory b = MessageLib.deserializeUpdateShares(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.shares, b.shares);
        assertEq(a.timestamp, b.timestamp);
        assertEq(a.isIssuance, b.isIssuance);
        assertEq(a.isSnapshot, b.isSnapshot);
        assertEq(a.nonce, b.nonce);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), 0);
    }

    // function testApprovedDeposits(
    //     uint64 poolId,
    //     bytes16 scId,
    //     uint128 assetId,
    //     uint128 assetAmount,
    //     uint128 pricePoolPerAsset
    // ) public pure {
    //     MessageLib.ApprovedDeposits memory a = MessageLib.ApprovedDeposits({
    //         poolId: poolId,
    //         scId: scId,
    //         assetId: assetId,
    //         assetAmount: assetAmount,
    //         pricePoolPerAsset: pricePoolPerAsset
    //     });

    //     MessageLib.ApprovedDeposits memory b = MessageLib.deserializeApprovedDeposits(a.serialize());

    //     assertEq(a.poolId, b.poolId);
    //     assertEq(a.scId, b.scId);
    //     assertEq(a.assetId, b.assetId);
    //     assertEq(a.assetAmount, b.assetAmount);
    //     assertEq(a.pricePoolPerAsset, b.pricePoolPerAsset);

    //     assertEq(a.serialize().messageLength(), a.serialize().length);
    //     assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    //     assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
    // }

    // function testRevokedShares(
    //     uint64 poolId,
    //     bytes16 scId,
    //     uint128 assetId,
    //     uint128 assetAmount,
    //     uint128 shareAmount,
    //     uint128 pricePoolPerShare
    // ) public pure {
    //     MessageLib.RevokedShares memory a = MessageLib.RevokedShares({
    //         poolId: poolId,
    //         scId: scId,
    //         assetId: assetId,
    //         assetAmount: assetAmount,
    //         shareAmount: shareAmount,
    //         pricePoolPerShare: pricePoolPerShare
    //     });

    //     MessageLib.RevokedShares memory b = MessageLib.deserializeRevokedShares(a.serialize());

    //     assertEq(a.poolId, b.poolId);
    //     assertEq(a.scId, b.scId);
    //     assertEq(a.assetId, b.assetId);
    //     assertEq(a.assetAmount, b.assetAmount);
    //     assertEq(a.shareAmount, b.shareAmount);
    //     assertEq(a.pricePoolPerShare, b.pricePoolPerShare);

    //     assertEq(a.serialize().messageLength(), a.serialize().length);
    //     assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    //     assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
    // }

    function testMaxAssetPriceAge(uint64 poolId, bytes16 scId, uint128 assetId, uint64 maxPriceAge) public pure {
        MessageLib.MaxAssetPriceAge memory a =
            MessageLib.MaxAssetPriceAge({poolId: poolId, scId: scId, assetId: assetId, maxPriceAge: maxPriceAge});
        MessageLib.MaxAssetPriceAge memory b = MessageLib.deserializeMaxAssetPriceAge(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.maxPriceAge, b.maxPriceAge);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
    }

    function testMaxSharePriceAge(uint64 poolId, bytes16 scId, uint64 maxPriceAge) public pure {
        MessageLib.MaxSharePriceAge memory a =
            MessageLib.MaxSharePriceAge({poolId: poolId, scId: scId, maxPriceAge: maxPriceAge});
        MessageLib.MaxSharePriceAge memory b = MessageLib.deserializeMaxSharePriceAge(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.maxPriceAge, b.maxPriceAge);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
        assertEq(a.serialize().messageSourceCentrifugeId(), PoolId.wrap(poolId).centrifugeId());
    }
}
