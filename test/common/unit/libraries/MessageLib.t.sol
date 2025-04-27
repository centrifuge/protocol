// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {MessageProofLib} from "src/common/libraries/MessageProofLib.sol";

import "forge-std/Test.sol";

contract TestMessageProofCompatibility is Test {
    function testMessageProofCompatibility() public pure {
        assertEq(uint8(MessageType._MessageProof), MessageProofLib.MESSAGE_PROOF_ID);
    }
}

// The following tests check that the function composition of deserializing and serializing equals to the identity:
//       I = deserialize º serialize
// NOTE. To fully ensure a good testing, use different values for each field.
contract TestMessageLibIdentities is Test {
    using MessageLib for *;

    function testInitiateRecovery(bytes32 hash_, bytes32 adapter, uint16 centrifugeId) public pure {
        MessageLib.InitiateRecovery memory a =
            MessageLib.InitiateRecovery({hash: hash_, adapter: adapter, centrifugeId: centrifugeId});
        MessageLib.InitiateRecovery memory b = MessageLib.deserializeInitiateRecovery(a.serialize());

        assertEq(a.hash, b.hash);
        assertEq(a.adapter, b.adapter);
        assertEq(a.centrifugeId, b.centrifugeId);

        assertEq(a.serialize().messageLength(), a.serialize().length);
    }

    function testDisputeRecovery(bytes32 hash_, bytes32 adapter, uint16 centrifugeId) public pure {
        MessageLib.DisputeRecovery memory a =
            MessageLib.DisputeRecovery({hash: hash_, adapter: adapter, centrifugeId: centrifugeId});
        MessageLib.DisputeRecovery memory b = MessageLib.deserializeDisputeRecovery(a.serialize());

        assertEq(a.hash, b.hash);
        assertEq(a.adapter, b.adapter);
        assertEq(a.centrifugeId, b.centrifugeId);

        assertEq(a.serialize().messageLength(), a.serialize().length);
    }

    function testScheduleUpgrade(bytes32 target) public pure {
        MessageLib.ScheduleUpgrade memory a = MessageLib.ScheduleUpgrade({target: target});
        MessageLib.ScheduleUpgrade memory b = MessageLib.deserializeScheduleUpgrade(a.serialize());

        assertEq(a.target, b.target);

        assertEq(a.serialize().messageLength(), a.serialize().length);
    }

    function testCancelUpgrade(bytes32 target) public pure {
        MessageLib.CancelUpgrade memory a = MessageLib.CancelUpgrade({target: target});
        MessageLib.CancelUpgrade memory b = MessageLib.deserializeCancelUpgrade(a.serialize());

        assertEq(a.target, b.target);

        assertEq(a.serialize().messageLength(), a.serialize().length);
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
    }

    function testRegisterAsset(uint128 assetId, uint8 decimals) public pure {
        MessageLib.RegisterAsset memory a = MessageLib.RegisterAsset({assetId: assetId, decimals: decimals});
        MessageLib.RegisterAsset memory b = MessageLib.deserializeRegisterAsset(a.serialize());

        assertEq(a.assetId, b.assetId);
        assertEq(a.decimals, b.decimals);

        assertEq(bytes(a.serialize()).length, a.serialize().messageLength());
    }

    function testNotifyPool(uint64 poolId) public pure {
        MessageLib.NotifyPool memory a = MessageLib.NotifyPool({poolId: poolId});
        MessageLib.NotifyPool memory b = MessageLib.deserializeNotifyPool(a.serialize());

        assertEq(a.poolId, b.poolId);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
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
    }

    function testUpdateShareHook(uint64 poolId, bytes16 scId, bytes32 hook) public pure {
        MessageLib.UpdateShareHook memory a = MessageLib.UpdateShareHook({poolId: poolId, scId: scId, hook: hook});
        MessageLib.UpdateShareHook memory b = MessageLib.deserializeUpdateShareHook(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.hook, b.hook);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testTransferShares(uint64 poolId, bytes16 scId, bytes32 receiver, uint128 amount) public pure {
        MessageLib.TransferShares memory a =
            MessageLib.TransferShares({poolId: poolId, scId: scId, receiver: receiver, amount: amount});
        MessageLib.TransferShares memory b = MessageLib.deserializeTransferShares(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.receiver, b.receiver);
        assertEq(a.amount, b.amount);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
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

        // Check the payload length is correctly encoded as little endian
        assertEq(a.payload.length, uint8(a.serialize()[a.serialize().messageLength() - a.payload.length - 1]));
    }

    function testUpdateRestrictionMember(bytes32 user, uint64 validUntil) public pure {
        MessageLib.UpdateRestrictionMember memory aa =
            MessageLib.UpdateRestrictionMember({user: user, validUntil: validUntil});
        MessageLib.UpdateRestrictionMember memory bb = MessageLib.deserializeUpdateRestrictionMember(aa.serialize());

        assertEq(aa.user, bb.user);
        assertEq(aa.validUntil, bb.validUntil);

        // This message is a submessage and has not static message length defined
    }

    function testUpdateRestrictionFreeze(bytes32 user) public pure {
        MessageLib.UpdateRestrictionFreeze memory aa = MessageLib.UpdateRestrictionFreeze({user: user});
        MessageLib.UpdateRestrictionFreeze memory bb = MessageLib.deserializeUpdateRestrictionFreeze(aa.serialize());

        assertEq(aa.user, bb.user);

        // This message is a submessage and has not static message length defined
    }

    function testUpdateRestrictionUnfreeze(bytes32 user) public pure {
        MessageLib.UpdateRestrictionUnfreeze memory aa = MessageLib.UpdateRestrictionUnfreeze({user: user});
        MessageLib.UpdateRestrictionUnfreeze memory bb = MessageLib.deserializeUpdateRestrictionUnfreeze(aa.serialize());

        assertEq(aa.user, bb.user);

        // This message is a submessage and has not static message length defined
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

        // Check the payload length is correctly encoded as little endian
        assertEq(a.payload.length, uint8(a.serialize()[a.serialize().messageLength() - a.payload.length - 1]));
    }

    function testUpdateContractVaultUpdate(bytes32 vaultOrFactory, uint128 assetId, uint8 kind) public pure {
        MessageLib.UpdateContractVaultUpdate memory a =
            MessageLib.UpdateContractVaultUpdate({vaultOrFactory: vaultOrFactory, assetId: assetId, kind: kind});
        MessageLib.UpdateContractVaultUpdate memory b = MessageLib.deserializeUpdateContractVaultUpdate(a.serialize());

        assertEq(a.vaultOrFactory, b.vaultOrFactory);
        assertEq(a.assetId, b.assetId);
        assertEq(a.kind, b.kind);

        // This message is a submessage and has not static message length defined
    }

    function testUpdateContractUpdateManager(bytes32 who, bool canManage) public pure {
        MessageLib.UpdateContractUpdateManager memory a =
            MessageLib.UpdateContractUpdateManager({who: who, canManage: canManage});
        MessageLib.UpdateContractUpdateManager memory b =
            MessageLib.deserializeUpdateContractUpdateManager(a.serialize());

        assertEq(a.who, b.who);
        assertEq(a.canManage, b.canManage);
        // This message is a submessage and has not static message length defined
    }

    function testUpdateContractMaxAssetPriceAge(uint128 assetId, uint64 maxPriceAge) public pure {
        MessageLib.UpdateContractMaxAssetPriceAge memory a =
            MessageLib.UpdateContractMaxAssetPriceAge({assetId: assetId, maxPriceAge: maxPriceAge});
        MessageLib.UpdateContractMaxAssetPriceAge memory b =
            MessageLib.deserializeUpdateContractMaxAssetPriceAge(a.serialize());

        assertEq(a.assetId, b.assetId);
        assertEq(a.maxPriceAge, b.maxPriceAge);
        // This message is a submessage and has not static message length defined
    }

    function testUpdateContractMaxSharePriceAge(uint64 maxPriceAge) public pure {
        MessageLib.UpdateContractMaxSharePriceAge memory a =
            MessageLib.UpdateContractMaxSharePriceAge({maxPriceAge: maxPriceAge});
        MessageLib.UpdateContractMaxSharePriceAge memory b =
            MessageLib.deserializeUpdateContractMaxSharePriceAge(a.serialize());

        assertEq(a.maxPriceAge, b.maxPriceAge);
        // This message is a submessage and has not static message length defined
    }

    function testUpdateContractValuation(bytes32 valuation) public pure {
        MessageLib.UpdateContractValuation memory a = MessageLib.UpdateContractValuation({valuation: valuation});
        MessageLib.UpdateContractValuation memory b = MessageLib.deserializeUpdateContractValuation(a.serialize());

        assertEq(a.valuation, b.valuation);
        // This message is a submessage and has not static message length defined
    }

    function testUpdateContractSyncDepositMaxReserve(uint128 assetId, uint128 maxReserve) public pure {
        MessageLib.UpdateContractSyncDepositMaxReserve memory a =
            MessageLib.UpdateContractSyncDepositMaxReserve({assetId: assetId, maxReserve: maxReserve});
        MessageLib.UpdateContractSyncDepositMaxReserve memory b =
            MessageLib.deserializeUpdateContractSyncDepositMaxReserve(a.serialize());

        assertEq(a.assetId, b.assetId);
        assertEq(a.maxReserve, b.maxReserve);
        // This message is a submessage and has not static message length defined
    }

    function testDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        public
        pure
    {
        MessageLib.DepositRequest memory a = MessageLib.DepositRequest({
            poolId: poolId,
            scId: scId,
            investor: investor,
            assetId: assetId,
            amount: amount
        });
        MessageLib.DepositRequest memory b = MessageLib.deserializeDepositRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.investor, b.investor);
        assertEq(a.assetId, b.assetId);
        assertEq(a.amount, b.amount);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        public
        pure
    {
        MessageLib.RedeemRequest memory a =
            MessageLib.RedeemRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId, amount: amount});
        MessageLib.RedeemRequest memory b = MessageLib.deserializeRedeemRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.investor, b.investor);
        assertEq(a.assetId, b.assetId);
        assertEq(a.amount, b.amount);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testFulfilledDepositRequest(
        uint64 poolId,
        bytes16 scId,
        bytes32 investor,
        uint128 assetId,
        uint128 assetAmount,
        uint128 shareAmount
    ) public pure {
        MessageLib.FulfilledDepositRequest memory a = MessageLib.FulfilledDepositRequest({
            poolId: poolId,
            scId: scId,
            investor: investor,
            assetId: assetId,
            assetAmount: assetAmount,
            shareAmount: shareAmount
        });
        MessageLib.FulfilledDepositRequest memory b = MessageLib.deserializeFulfilledDepositRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.investor, b.investor);
        assertEq(a.assetId, b.assetId);
        assertEq(a.assetAmount, b.assetAmount);
        assertEq(a.shareAmount, b.shareAmount);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testFulfilledRedeemRequest(
        uint64 poolId,
        bytes16 scId,
        bytes32 investor,
        uint128 assetId,
        uint128 assetAmount,
        uint128 shareAmount
    ) public pure {
        MessageLib.FulfilledRedeemRequest memory a = MessageLib.FulfilledRedeemRequest({
            poolId: poolId,
            scId: scId,
            investor: investor,
            assetId: assetId,
            assetAmount: assetAmount,
            shareAmount: shareAmount
        });
        MessageLib.FulfilledRedeemRequest memory b = MessageLib.deserializeFulfilledRedeemRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.investor, b.investor);
        assertEq(a.assetId, b.assetId);
        assertEq(a.assetAmount, b.assetAmount);
        assertEq(a.shareAmount, b.shareAmount);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testCancelDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) public pure {
        MessageLib.CancelDepositRequest memory a =
            MessageLib.CancelDepositRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId});
        MessageLib.CancelDepositRequest memory b = MessageLib.deserializeCancelDepositRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.investor, b.investor);
        assertEq(a.assetId, b.assetId);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testCancelRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) public pure {
        MessageLib.CancelRedeemRequest memory a =
            MessageLib.CancelRedeemRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId});
        MessageLib.CancelRedeemRequest memory b = MessageLib.deserializeCancelRedeemRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.investor, b.investor);
        assertEq(a.assetId, b.assetId);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testFulfilledCancelDepositRequest(
        uint64 poolId,
        bytes16 scId,
        bytes32 investor,
        uint128 assetId,
        uint128 cancelledAmount
    ) public pure {
        MessageLib.FulfilledCancelDepositRequest memory a = MessageLib.FulfilledCancelDepositRequest({
            poolId: poolId,
            scId: scId,
            investor: investor,
            assetId: assetId,
            cancelledAmount: cancelledAmount
        });
        MessageLib.FulfilledCancelDepositRequest memory b =
            MessageLib.deserializeFulfilledCancelDepositRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.investor, b.investor);
        assertEq(a.assetId, b.assetId);
        assertEq(a.cancelledAmount, b.cancelledAmount);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testFulfilledCancelRedeemRequest(
        uint64 poolId,
        bytes16 scId,
        bytes32 investor,
        uint128 assetId,
        uint128 cancelledShares
    ) public pure {
        MessageLib.FulfilledCancelRedeemRequest memory a = MessageLib.FulfilledCancelRedeemRequest({
            poolId: poolId,
            scId: scId,
            investor: investor,
            assetId: assetId,
            cancelledShares: cancelledShares
        });
        MessageLib.FulfilledCancelRedeemRequest memory b =
            MessageLib.deserializeFulfilledCancelRedeemRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.investor, b.investor);
        assertEq(a.assetId, b.assetId);
        assertEq(a.cancelledShares, b.cancelledShares);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testUpdateHoldingAmount(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        bytes32 who,
        uint128 amount,
        uint128 pricePerUnit,
        uint64 timestamp,
        bool isIncrease
    ) public pure {
        MessageLib.UpdateHoldingAmount memory a = MessageLib.UpdateHoldingAmount({
            poolId: poolId,
            scId: scId,
            assetId: assetId,
            who: who,
            amount: amount,
            pricePerUnit: pricePerUnit,
            timestamp: timestamp,
            isIncrease: isIncrease
        });

        MessageLib.UpdateHoldingAmount memory b = MessageLib.deserializeUpdateHoldingAmount(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.who, b.who);
        assertEq(a.amount, b.amount);
        assertEq(a.pricePerUnit, b.pricePerUnit);
        assertEq(a.timestamp, b.timestamp);
        assertEq(a.isIncrease, b.isIncrease);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testUpdateShares(uint64 poolId, bytes16 scId, uint128 shares, uint64 timestamp, bool isIssuance)
        public
        pure
    {
        MessageLib.UpdateShares memory a = MessageLib.UpdateShares({
            poolId: poolId,
            scId: scId,
            shares: shares,
            timestamp: timestamp,
            isIssuance: isIssuance
        });

        MessageLib.UpdateShares memory b = MessageLib.deserializeUpdateShares(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.shares, b.shares);
        assertEq(a.timestamp, b.timestamp);
        assertEq(a.isIssuance, b.isIssuance);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testApprovedDeposits(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        uint128 assetAmount,
        uint128 pricePoolPerAsset
    ) public pure {
        MessageLib.ApprovedDeposits memory a = MessageLib.ApprovedDeposits({
            poolId: poolId,
            scId: scId,
            assetId: assetId,
            assetAmount: assetAmount,
            pricePoolPerAsset: pricePoolPerAsset
        });

        MessageLib.ApprovedDeposits memory b = MessageLib.deserializeApprovedDeposits(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.assetAmount, b.assetAmount);
        assertEq(a.pricePoolPerAsset, b.pricePoolPerAsset);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testRevokedShares(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        uint128 assetAmount,
        uint128 shareAmount,
        uint128 pricePoolPerShare
    ) public pure {
        MessageLib.RevokedShares memory a = MessageLib.RevokedShares({
            poolId: poolId,
            scId: scId,
            assetId: assetId,
            assetAmount: assetAmount,
            shareAmount: shareAmount,
            pricePoolPerShare: pricePoolPerShare
        });

        MessageLib.RevokedShares memory b = MessageLib.deserializeRevokedShares(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.assetAmount, b.assetAmount);
        assertEq(a.shareAmount, b.shareAmount);
        assertEq(a.pricePoolPerShare, b.pricePoolPerShare);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testTriggerIssueShares(uint64 poolId, bytes16 scId, bytes32 who, uint128 shares) public pure {
        MessageLib.TriggerIssueShares memory a =
            MessageLib.TriggerIssueShares({poolId: poolId, scId: scId, who: who, shares: shares});

        MessageLib.TriggerIssueShares memory b = MessageLib.deserializeTriggerIssueShares(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.who, b.who);
        assertEq(a.shares, b.shares);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testTriggerSubmitQueuedShares(uint64 poolId, bytes16 scId) public pure {
        MessageLib.TriggerSubmitQueuedShares memory a =
            MessageLib.TriggerSubmitQueuedShares({poolId: poolId, scId: scId});
        MessageLib.TriggerSubmitQueuedShares memory b = MessageLib.deserializeTriggerSubmitQueuedShares(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testTriggerSubmitQueuedAssets(uint64 poolId, bytes16 scId, uint128 assetId) public pure {
        MessageLib.TriggerSubmitQueuedAssets memory a =
            MessageLib.TriggerSubmitQueuedAssets({poolId: poolId, scId: scId, assetId: assetId});
        MessageLib.TriggerSubmitQueuedAssets memory b = MessageLib.deserializeTriggerSubmitQueuedAssets(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testSetQueue(uint64 poolId, bytes16 scId, bool enabled) public pure {
        MessageLib.SetQueue memory a = MessageLib.SetQueue({poolId: poolId, scId: scId, enabled: enabled});
        MessageLib.SetQueue memory b = MessageLib.deserializeSetQueue(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.enabled, b.enabled);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }
}
