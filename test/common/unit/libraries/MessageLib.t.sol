// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MessageLib} from "src/common/libraries/MessageLib.sol";

import "forge-std/Test.sol";

contract MessageLibTest is Test {
    using MessageLib for *;

    /* The following tests check the function composition of deserializing and serializing equals to the identity:
        I = deserialize º serialize
    */

    function testMessageProof() public pure {
        MessageLib.MessageProof memory a = MessageLib.MessageProof({hash: bytes32("hash")});
        MessageLib.MessageProof memory b = MessageLib.deserializeMessageProof(a.serialize());

        assertEq(a.hash, b.hash);
    }

    function testInitializeMessageRecovery() public pure {
        MessageLib.InitiateMessageRecovery memory a =
            MessageLib.InitiateMessageRecovery({hash: bytes32("hash"), adapter: bytes32("adapter")});
        MessageLib.InitiateMessageRecovery memory b = MessageLib.deserializeInitiateMessageRecovery(a.serialize());

        assertEq(a.hash, b.hash);
        assertEq(a.adapter, b.adapter);
    }

    function testDisputeMessageRecovery() public pure {
        MessageLib.DisputeMessageRecovery memory a =
            MessageLib.DisputeMessageRecovery({hash: bytes32("hash"), adapter: bytes32("adapter")});
        MessageLib.DisputeMessageRecovery memory b = MessageLib.deserializeDisputeMessageRecovery(a.serialize());

        assertEq(a.hash, b.hash);
        assertEq(a.adapter, b.adapter);
    }

    function testScheduleUpgrade() public pure {
        MessageLib.ScheduleUpgrade memory a = MessageLib.ScheduleUpgrade({target: bytes32("contract")});
        MessageLib.ScheduleUpgrade memory b = MessageLib.deserializeScheduleUpgrade(a.serialize());

        assertEq(a.target, b.target);
    }

    function testCancelUpgrade() public pure {
        MessageLib.CancelUpgrade memory a = MessageLib.CancelUpgrade({target: bytes32("contract")});
        MessageLib.CancelUpgrade memory b = MessageLib.deserializeCancelUpgrade(a.serialize());

        assertEq(a.target, b.target);
    }

    function testRecoverTokens() public pure {
        MessageLib.RecoverTokens memory a = MessageLib.RecoverTokens({
            target: bytes32("contract"),
            token: bytes32("token"),
            to: bytes32("to"),
            amount: 123
        });
        MessageLib.RecoverTokens memory b = MessageLib.deserializeRecoverTokens(a.serialize());

        assertEq(a.target, b.target);
        assertEq(a.token, b.token);
        assertEq(a.to, b.to);
        assertEq(a.amount, b.amount);
    }

    function testUpdateGasPrice() public pure {
        MessageLib.UpdateGasPrice memory a = MessageLib.UpdateGasPrice({price: 42, timestamp: 0x12345678});
        MessageLib.UpdateGasPrice memory b = MessageLib.deserializeUpdateGasPrice(a.serialize());

        assertEq(a.price, b.price);
        assertEq(a.timestamp, b.timestamp);
    }

    function testRegisterAsset() public pure {
        MessageLib.RegisterAsset memory a = MessageLib.RegisterAsset({assetId: 1, name: "n", symbol: "s", decimals: 4});
        MessageLib.RegisterAsset memory b = MessageLib.deserializeRegisterAsset(a.serialize());

        assertEq(a.assetId, b.assetId);
        assertEq(a.name, b.name);
        assertEq(a.symbol, b.symbol);
        assertEq(a.decimals, b.decimals);
    }

    function testNotifyPool() public pure {
        MessageLib.NotifyPool memory a = MessageLib.NotifyPool({poolId: 1});
        MessageLib.NotifyPool memory b = MessageLib.deserializeNotifyPool(a.serialize());

        assertEq(a.poolId, b.poolId);
    }

    function testNotifyShareClass() public pure {
        MessageLib.NotifyShareClass memory a = MessageLib.NotifyShareClass({
            poolId: 1,
            scId: bytes16("sc"),
            name: "n",
            symbol: "s",
            decimals: 18,
            hook: bytes32("hook")
        });
        MessageLib.NotifyShareClass memory b = MessageLib.deserializeNotifyShareClass(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.name, b.name);
        assertEq(a.symbol, b.symbol);
        assertEq(a.decimals, b.decimals);
        assertEq(a.hook, b.hook);
    }

    function testAllowAsset() public pure {
        MessageLib.AllowAsset memory a = MessageLib.AllowAsset({poolId: 1, scId: bytes16("sc"), assetId: 5});
        MessageLib.AllowAsset memory b = MessageLib.deserializeAllowAsset(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
    }

    function testDisallowAsset() public pure {
        MessageLib.DisallowAsset memory a = MessageLib.DisallowAsset({poolId: 1, scId: bytes16("sc"), assetId: 5});
        MessageLib.DisallowAsset memory b = MessageLib.deserializeDisallowAsset(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
    }

    function testUpdateShareClassPrice() public pure {
        MessageLib.UpdateShareClassPrice memory a = MessageLib.UpdateShareClassPrice({
            poolId: 1,
            scId: bytes16("sc"),
            assetId: 5,
            price: 42,
            timestamp: 0x12345678
        });
        MessageLib.UpdateShareClassPrice memory b = MessageLib.deserializeUpdateShareClassPrice(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.assetId, b.assetId);
        assertEq(a.price, b.price);
        assertEq(a.timestamp, b.timestamp);
    }

    function testUpdateShareClassMetadata() public pure {
        MessageLib.UpdateShareClassMetadata memory a =
            MessageLib.UpdateShareClassMetadata({poolId: 1, scId: bytes16("sc"), name: "n", symbol: "s"});
        MessageLib.UpdateShareClassMetadata memory b = MessageLib.deserializeUpdateShareClassMetadata(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.name, b.name);
        assertEq(a.symbol, b.symbol);
    }

    function testUpdateShareClassHook() public pure {
        MessageLib.UpdateShareClassHook memory a =
            MessageLib.UpdateShareClassHook({poolId: 1, scId: bytes16("sc"), hook: bytes32("hook")});
        MessageLib.UpdateShareClassHook memory b = MessageLib.deserializeUpdateShareClassHook(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.hook, b.hook);
    }

    function testTransferShares() public pure {
        MessageLib.TransferShares memory a =
            MessageLib.TransferShares({poolId: 1, scId: bytes16("sc"), recipient: bytes32("bob"), amount: 8});
        MessageLib.TransferShares memory b = MessageLib.deserializeTransferShares(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.recipient, b.recipient);
        assertEq(a.amount, b.amount);
    }

    function testUpdateRestriction() public pure {
        MessageLib.UpdateRestriction memory a =
            MessageLib.UpdateRestriction({poolId: 1, scId: bytes16("sc"), payload: bytes("ABCD")});
        MessageLib.UpdateRestriction memory b = MessageLib.deserializeUpdateRestriction(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.payload, b.payload);
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
    }

    function testCancelDepositRequest() public pure {
        MessageLib.CancelDepositRequest memory a =
            MessageLib.CancelDepositRequest({poolId: 1, scId: bytes16("sc"), investor: bytes32("alice"), assetId: 5});
        MessageLib.CancelDepositRequest memory b = MessageLib.deserializeCancelDepositRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.investor, b.investor);
        assertEq(a.assetId, b.assetId);
    }

    function testCancelRedeemRequest() public pure {
        MessageLib.CancelRedeemRequest memory a =
            MessageLib.CancelRedeemRequest({poolId: 1, scId: bytes16("sc"), investor: bytes32("alice"), assetId: 5});
        MessageLib.CancelRedeemRequest memory b = MessageLib.deserializeCancelRedeemRequest(a.serialize());

        assertEq(a.poolId, b.poolId);
        assertEq(a.scId, b.scId);
        assertEq(a.investor, b.investor);
        assertEq(a.assetId, b.assetId);
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
    }

    // TODO: rest of the messages
}
