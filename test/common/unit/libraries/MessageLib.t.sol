// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {JournalEntry} from "src/common/libraries/JournalEntryLib.sol";
import {AccountId} from "src/common/types/AccountId.sol";

import "forge-std/Test.sol";

// The following tests check that the function composition of deserializing and serializing equals to the identity:
//       I = deserialize º serialize
// NOTE. To fully ensure a good testing, use different values for each field.
contract TestMessageLibIdentities is Test {
    using MessageLib for *;

    function testMessageProof() public pure {
        MessageLib.MessageProof memory a = MessageLib.MessageProof({hash: bytes32("hash")});
        MessageLib.MessageProof memory b = MessageLib.deserializeMessageProof(a.serialize());

        assertEq(a.hash, b.hash);

        assertEq(a.serialize().messageLength(), a.serialize().length);
    }

    function testInitiateMessageRecovery() public pure {
        MessageLib.InitiateMessageRecovery memory a =
            MessageLib.InitiateMessageRecovery({hash: bytes32("hash"), adapter: bytes32("adapter"), centrifugeId: 23});
        MessageLib.InitiateMessageRecovery memory b = MessageLib.deserializeInitiateMessageRecovery(a.serialize());

        assertEq(a.hash, b.hash);
        assertEq(a.adapter, b.adapter);
        assertEq(a.centrifugeId, b.centrifugeId);

        assertEq(a.serialize().messageLength(), a.serialize().length);
    }

    function testDisputeMessageRecovery() public pure {
        MessageLib.DisputeMessageRecovery memory a =
            MessageLib.DisputeMessageRecovery({hash: bytes32("hash"), adapter: bytes32("adapter"), centrifugeId: 23});
        MessageLib.DisputeMessageRecovery memory b = MessageLib.deserializeDisputeMessageRecovery(a.serialize());

        assertEq(a.hash, b.hash);
        assertEq(a.adapter, b.adapter);
        assertEq(a.centrifugeId, b.centrifugeId);

        assertEq(a.serialize().messageLength(), a.serialize().length);
    }

    function testScheduleUpgrade() public pure {
        MessageLib.ScheduleUpgrade memory a = MessageLib.ScheduleUpgrade({target: bytes32("contract")});
        MessageLib.ScheduleUpgrade memory b = MessageLib.deserializeScheduleUpgrade(a.serialize());

        assertEq(a.target, b.target);

        assertEq(a.serialize().messageLength(), a.serialize().length);
    }

    function testCancelUpgrade() public pure {
        MessageLib.CancelUpgrade memory a = MessageLib.CancelUpgrade({target: bytes32("contract")});
        MessageLib.CancelUpgrade memory b = MessageLib.deserializeCancelUpgrade(a.serialize());

        assertEq(a.target, b.target);

        assertEq(a.serialize().messageLength(), a.serialize().length);
    }

    function testRecoverTokens() public pure {
        MessageLib.RecoverTokens memory a = MessageLib.RecoverTokens({
            target: bytes32("contract"),
            token: bytes32("token"),
            tokenId: uint256(987),
            to: bytes32("to"),
            amount: 123
        });
        MessageLib.RecoverTokens memory b = MessageLib.deserializeRecoverTokens(a.serialize());

        assertEq(a.target, b.target);
        assertEq(a.token, b.token);
        assertEq(a.tokenId, b.tokenId);
        assertEq(a.to, b.to);
        assertEq(a.amount, b.amount);

        assertEq(a.serialize().messageLength(), a.serialize().length, "XXX");
    }

    function testRegisterAsset() public pure {
        MessageLib.RegisterAsset memory a = MessageLib.RegisterAsset({assetId: 1, decimals: 4});
        MessageLib.RegisterAsset memory b = MessageLib.deserializeRegisterAsset(a.serialize());

        assertEq(a.assetId, b.assetId);
        assertEq(a.decimals, b.decimals);

        assertEq(bytes(a.serialize()).length, a.serialize().messageLength());
        assertEq(a.serialize().messageLength(), 18);
    }

    function testNotifyPool() public pure {
        MessageLib.NotifyPool memory a = MessageLib.NotifyPool({poolId: 1});
        MessageLib.NotifyPool memory b = MessageLib.deserializeNotifyPool(a.serialize());

        assertEq(a.poolId, b.poolId);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testNotifyShareClass() public pure {
        MessageLib.NotifyShareClass memory a = MessageLib.NotifyShareClass({
            poolId: 1,
            scId: bytes16("sc"),
            name: "n",
            symbol: "s",
            decimals: 18,
            salt: bytes32("salt"),
            hook: bytes32("hook")
        });
        MessageLib.NotifyShareClass memory b = MessageLib.deserializeNotifyShareClass(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.name, b.name);
        assertEq(a.symbol, b.symbol);
        assertEq(a.decimals, b.decimals);
        assertEq(a.salt, b.salt);
        assertEq(a.hook, b.hook);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testNotifyPricePoolPerShare() public pure {
        MessageLib.NotifyPricePoolPerShare memory a =
            MessageLib.NotifyPricePoolPerShare({poolId: 1, scId: bytes16("sc"), price: 42, timestamp: 0x12345678});
        MessageLib.NotifyPricePoolPerShare memory b = MessageLib.deserializeNotifyPricePoolPerShare(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.price, b.price);
        assertEq(a.timestamp, b.timestamp);

        assertEq(a.serialize().messageLength(), a.serialize().length);
    }

    function testNotifyPricePoolPerAsset() public pure {
        MessageLib.NotifyPricePoolPerAsset memory a = MessageLib.NotifyPricePoolPerAsset({
            poolId: 1,
            scId: bytes16("sc"),
            assetId: 5,
            price: 42,
            timestamp: 0x12345678
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

    function testUpdateShareClassMetadata() public pure {
        MessageLib.UpdateShareClassMetadata memory a =
            MessageLib.UpdateShareClassMetadata({poolId: 1, scId: bytes16("sc"), name: "n", symbol: "s"});
        MessageLib.UpdateShareClassMetadata memory b = MessageLib.deserializeUpdateShareClassMetadata(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.name, b.name);
        assertEq(a.symbol, b.symbol);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testUpdateShareClassHook() public pure {
        MessageLib.UpdateShareClassHook memory a =
            MessageLib.UpdateShareClassHook({poolId: 1, scId: bytes16("sc"), hook: bytes32("hook")});
        MessageLib.UpdateShareClassHook memory b = MessageLib.deserializeUpdateShareClassHook(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.hook, b.hook);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testTransferShares() public pure {
        MessageLib.TransferShares memory a =
            MessageLib.TransferShares({poolId: 1, scId: bytes16("sc"), receiver: bytes32("bob"), amount: 8});
        MessageLib.TransferShares memory b = MessageLib.deserializeTransferShares(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.receiver, b.receiver);
        assertEq(a.amount, b.amount);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testUpdateRestriction() public pure {
        MessageLib.UpdateRestriction memory a =
            MessageLib.UpdateRestriction({poolId: 1, scId: bytes16("sc"), payload: bytes("payload")});
        MessageLib.UpdateRestriction memory b = MessageLib.deserializeUpdateRestriction(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.payload, b.payload);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);

        // Check the payload length is correctly encoded as little endian
        assertEq(a.payload.length, uint8(a.serialize()[a.serialize().messageLength() - a.payload.length - 1]));
    }

    function testUpdateRestrictionMember() public pure {
        MessageLib.UpdateRestrictionMember memory aa =
            MessageLib.UpdateRestrictionMember({user: bytes32("bob"), validUntil: 0x12345678});
        MessageLib.UpdateRestrictionMember memory bb = MessageLib.deserializeUpdateRestrictionMember(aa.serialize());

        assertEq(aa.user, bb.user);
        assertEq(aa.validUntil, bb.validUntil);

        // This message is a submessage and has not static message length defined
    }

    function testUpdateRestrictionFreeze() public pure {
        MessageLib.UpdateRestrictionFreeze memory aa = MessageLib.UpdateRestrictionFreeze({user: bytes32("bob")});
        MessageLib.UpdateRestrictionFreeze memory bb = MessageLib.deserializeUpdateRestrictionFreeze(aa.serialize());

        assertEq(aa.user, bb.user);

        // This message is a submessage and has not static message length defined
    }

    function testUpdateRestrictionUnfreeze() public pure {
        MessageLib.UpdateRestrictionUnfreeze memory aa = MessageLib.UpdateRestrictionUnfreeze({user: bytes32("bob")});
        MessageLib.UpdateRestrictionUnfreeze memory bb = MessageLib.deserializeUpdateRestrictionUnfreeze(aa.serialize());

        assertEq(aa.user, bb.user);

        // This message is a submessage and has not static message length defined
    }

    function testUpdateContract() public pure {
        MessageLib.UpdateContract memory a = MessageLib.UpdateContract({
            poolId: 1,
            scId: bytes16("sc"),
            target: bytes32("updateContract"),
            payload: bytes("ABCD")
        });
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

    function testUpdateContractVaultUpdate() public pure {
        MessageLib.UpdateContractVaultUpdate memory a =
            MessageLib.UpdateContractVaultUpdate({vaultOrFactory: bytes32("address"), assetId: 1, kind: 2});
        MessageLib.UpdateContractVaultUpdate memory b = MessageLib.deserializeUpdateContractVaultUpdate(a.serialize());

        assertEq(a.vaultOrFactory, b.vaultOrFactory);
        assertEq(a.assetId, b.assetId);
        assertEq(a.kind, b.kind);

        // This message is a submessage and has not static message length defined
    }

    function testUpdateContractMaxAssetPriceAge() public pure {
        MessageLib.UpdateContractMaxAssetPriceAge memory a =
            MessageLib.UpdateContractMaxAssetPriceAge({assetId: 1, maxPriceAge: 42});
        MessageLib.UpdateContractMaxAssetPriceAge memory b =
            MessageLib.deserializeUpdateContractMaxAssetPriceAge(a.serialize());

        assertEq(a.assetId, b.assetId);
        assertEq(a.maxPriceAge, b.maxPriceAge);
        // This message is a submessage and has not static message length defined
    }

    function testUpdateContractMaxSharePriceAge() public pure {
        MessageLib.UpdateContractMaxSharePriceAge memory a =
            MessageLib.UpdateContractMaxSharePriceAge({maxPriceAge: 42});
        MessageLib.UpdateContractMaxSharePriceAge memory b =
            MessageLib.deserializeUpdateContractMaxSharePriceAge(a.serialize());

        assertEq(a.maxPriceAge, b.maxPriceAge);
        // This message is a submessage and has not static message length defined
    }

    function testUpdateContractValuation() public pure {
        MessageLib.UpdateContractValuation memory a = MessageLib.UpdateContractValuation({
            poolId: 42,
            scId: bytes16("sc"),
            assetId: 1337,
            valuation: bytes32("valuation")
        });
        MessageLib.UpdateContractValuation memory b = MessageLib.deserializeUpdateContractValuation(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.valuation, b.valuation);
        // This message is a submessage and has not static message length defined
    }

    function testDepositRequest() public pure {
        MessageLib.DepositRequest memory a = MessageLib.DepositRequest({
            poolId: 1,
            scId: bytes16("sc"),
            investor: bytes32("alice"),
            assetId: 5,
            amount: 8
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

    function testRedeemRequest() public pure {
        MessageLib.RedeemRequest memory a = MessageLib.RedeemRequest({
            poolId: 1,
            scId: bytes16("sc"),
            investor: bytes32("alice"),
            assetId: 5,
            amount: 8
        });
        MessageLib.RedeemRequest memory b = MessageLib.deserializeRedeemRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.investor, b.investor);
        assertEq(a.assetId, b.assetId);
        assertEq(a.amount, b.amount);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testFulfilledDepositRequest() public pure {
        MessageLib.FulfilledDepositRequest memory a = MessageLib.FulfilledDepositRequest({
            poolId: 1,
            scId: bytes16("sc"),
            investor: bytes32("alice"),
            assetId: 5,
            assetAmount: 8,
            shareAmount: 7
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

    function testFulfilledRedeemRequest() public pure {
        MessageLib.FulfilledRedeemRequest memory a = MessageLib.FulfilledRedeemRequest({
            poolId: 1,
            scId: bytes16("sc"),
            investor: bytes32("alice"),
            assetId: 5,
            assetAmount: 8,
            shareAmount: 7
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

    function testCancelDepositRequest() public pure {
        MessageLib.CancelDepositRequest memory a =
            MessageLib.CancelDepositRequest({poolId: 1, scId: bytes16("sc"), investor: bytes32("alice"), assetId: 5});
        MessageLib.CancelDepositRequest memory b = MessageLib.deserializeCancelDepositRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.investor, b.investor);
        assertEq(a.assetId, b.assetId);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testCancelRedeemRequest() public pure {
        MessageLib.CancelRedeemRequest memory a =
            MessageLib.CancelRedeemRequest({poolId: 1, scId: bytes16("sc"), investor: bytes32("alice"), assetId: 5});
        MessageLib.CancelRedeemRequest memory b = MessageLib.deserializeCancelRedeemRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.investor, b.investor);
        assertEq(a.assetId, b.assetId);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testFulfilledCancelDepositRequest() public pure {
        MessageLib.FulfilledCancelDepositRequest memory a = MessageLib.FulfilledCancelDepositRequest({
            poolId: 1,
            scId: bytes16("sc"),
            investor: bytes32("alice"),
            assetId: 5,
            cancelledAmount: 8
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

    function testFulfilledCancelRedeemRequest() public pure {
        MessageLib.FulfilledCancelRedeemRequest memory a = MessageLib.FulfilledCancelRedeemRequest({
            poolId: 1,
            scId: bytes16("sc"),
            investor: bytes32("alice"),
            assetId: 5,
            cancelledShares: 8
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

    function testTriggerRedeemRequest() public pure {
        MessageLib.TriggerRedeemRequest memory a = MessageLib.TriggerRedeemRequest({
            poolId: 1,
            scId: bytes16("sc"),
            investor: bytes32("alice"),
            assetId: 5,
            shares: 8
        });
        MessageLib.TriggerRedeemRequest memory b = MessageLib.deserializeTriggerRedeemRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.investor, b.investor);
        assertEq(a.assetId, b.assetId);
        assertEq(a.shares, b.shares);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testUpdateHoldingAmount() public pure {
        JournalEntry[] memory debits = new JournalEntry[](3);
        debits[0] = JournalEntry({accountId: AccountId.wrap(9), amount: 1});
        debits[1] = JournalEntry({accountId: AccountId.wrap(8), amount: 2});
        debits[2] = JournalEntry({accountId: AccountId.wrap(7), amount: 3});

        JournalEntry[] memory credits = new JournalEntry[](2);
        credits[0] = JournalEntry({accountId: AccountId.wrap(1), amount: 4});
        credits[1] = JournalEntry({accountId: AccountId.wrap(3), amount: 5});

        MessageLib.UpdateHoldingAmount memory a = MessageLib.UpdateHoldingAmount({
            poolId: 1,
            scId: bytes16("sc"),
            assetId: 5,
            who: bytes32("alice"),
            amount: 100,
            pricePerUnit: 23,
            timestamp: 12345,
            isIncrease: false,
            debits: debits,
            credits: credits
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
        _checkEntries(a.debits, b.debits);
        _checkEntries(a.credits, b.credits);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testUpdateHoldingValue() public pure {
        MessageLib.UpdateHoldingValue memory a = MessageLib.UpdateHoldingValue({
            poolId: 1,
            scId: bytes16("sc"),
            assetId: 5,
            pricePerUnit: 23,
            timestamp: 12345
        });
        MessageLib.UpdateHoldingValue memory b = MessageLib.deserializeUpdateHoldingValue(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.pricePerUnit, b.pricePerUnit);
        assertEq(a.timestamp, b.timestamp);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testUpdateShares() public pure {
        MessageLib.UpdateShares memory a = MessageLib.UpdateShares({
            poolId: 1,
            scId: bytes16("sc"),
            who: bytes32("alice"),
            pricePerShare: 23,
            shares: 100,
            timestamp: 12345,
            isIssuance: true
        });

        MessageLib.UpdateShares memory b = MessageLib.deserializeUpdateShares(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.who, b.who);
        assertEq(a.shares, b.shares);
        assertEq(a.pricePerShare, b.pricePerShare);
        assertEq(a.timestamp, b.timestamp);
        assertEq(a.isIssuance, b.isIssuance);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testApprovedDeposits() public pure {
        MessageLib.ApprovedDeposits memory a =
            MessageLib.ApprovedDeposits({poolId: 1, scId: bytes16("sc"), assetId: 12345, assetAmount: 456789});

        MessageLib.ApprovedDeposits memory b = MessageLib.deserializeApprovedDeposits(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.assetAmount, b.assetAmount);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testUpdateJournal() public pure {
        JournalEntry[] memory debits = new JournalEntry[](3);
        debits[0] = JournalEntry({accountId: AccountId.wrap(9), amount: 1});
        debits[1] = JournalEntry({accountId: AccountId.wrap(8), amount: 2});
        debits[2] = JournalEntry({accountId: AccountId.wrap(7), amount: 3});

        JournalEntry[] memory credits = new JournalEntry[](2);
        credits[0] = JournalEntry({accountId: AccountId.wrap(1), amount: 4});
        credits[1] = JournalEntry({accountId: AccountId.wrap(3), amount: 5});

        MessageLib.UpdateJournal memory a = MessageLib.UpdateJournal({poolId: 1, debits: debits, credits: credits});
        MessageLib.UpdateJournal memory b = MessageLib.deserializeUpdateJournal(a.serialize());

        assertEq(a.poolId, b.poolId);
        _checkEntries(a.debits, b.debits);
        _checkEntries(a.credits, b.credits);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testTriggerUpdateHoldingAmount() public pure {
        JournalEntry[] memory debits = new JournalEntry[](3);
        debits[0] = JournalEntry({accountId: AccountId.wrap(9), amount: 1});
        debits[1] = JournalEntry({accountId: AccountId.wrap(8), amount: 2});
        debits[2] = JournalEntry({accountId: AccountId.wrap(7), amount: 3});

        JournalEntry[] memory credits = new JournalEntry[](2);
        credits[0] = JournalEntry({accountId: AccountId.wrap(1), amount: 4});
        credits[1] = JournalEntry({accountId: AccountId.wrap(3), amount: 5});

        MessageLib.TriggerUpdateHoldingAmount memory a = MessageLib.TriggerUpdateHoldingAmount({
            poolId: 1,
            scId: bytes16("sc"),
            assetId: 5,
            who: bytes32("alice"),
            amount: 100,
            pricePerUnit: 23,
            isIncrease: false,
            debits: debits,
            credits: credits
        });

        MessageLib.TriggerUpdateHoldingAmount memory b = MessageLib.deserializeTriggerUpdateHoldingAmount(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.who, b.who);
        assertEq(a.amount, b.amount);
        assertEq(a.pricePerUnit, b.pricePerUnit);
        assertEq(a.isIncrease, b.isIncrease);
        _checkEntries(a.debits, b.debits);
        _checkEntries(a.credits, b.credits);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function testTriggerUpdateShares() public pure {
        MessageLib.TriggerUpdateShares memory a = MessageLib.TriggerUpdateShares({
            poolId: 1,
            scId: bytes16("sc"),
            who: bytes32("alice"),
            pricePerShare: 23,
            shares: 100,
            isIssuance: false
        });

        MessageLib.TriggerUpdateShares memory b = MessageLib.deserializeTriggerUpdateShares(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.who, b.who);
        assertEq(a.pricePerShare, b.pricePerShare);
        assertEq(a.shares, b.shares);
        assertEq(a.isIssuance, b.isIssuance);

        assertEq(a.serialize().messageLength(), a.serialize().length);
        assertEq(a.serialize().messagePoolId().raw(), a.poolId);
    }

    function _checkEntries(JournalEntry[] memory a, JournalEntry[] memory b) private pure {
        for (uint256 i = 0; i < a.length; i++) {
            assertEq(a[i].accountId.raw(), b[i].accountId.raw());
            assertEq(a[i].amount, b[i].amount);
        }

        assertEq(a.length, b.length);
    }
}
