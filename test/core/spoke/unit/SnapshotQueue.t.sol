// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {SnapshotQueue} from "../../../../src/core/spoke/SnapshotQueue.sol";
import {ISnapshotQueue} from "../../../../src/core/spoke/interfaces/ISnapshotQueue.sol";
import {ISpokeMessageSender} from "../../../../src/core/messaging/interfaces/IGatewaySenders.sol";

import "forge-std/Test.sol";

contract QueuesTest is Test {
    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");

    uint128 constant AMOUNT = 100;
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("scId"));
    AssetId constant ASSET_20 = AssetId.wrap(3);
    AssetId constant ASSET_6909_1 = AssetId.wrap(4);
    bool constant IS_ISSUANCE = true;
    bool constant IS_DEPOSIT = true;
    bool constant IS_SNAPSHOT = true;

    SnapshotQueue snapshotQueue = new SnapshotQueue(AUTH);
}

contract QueuesTestAuth is QueuesTest {
    function testErrNotAuthorizedQueueAssets() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, IS_DEPOSIT);
    }

    function testErrNotAuthorizedQueueShares() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);
    }

    function testErrNotAuthorizedFlushAssets() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        snapshotQueue.flushAssets(POOL_A, SC_1, ASSET_20);
    }

    function testErrNotAuthorizedFlushShares() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        snapshotQueue.flushShares(POOL_A, SC_1);
    }
}

contract QueuesTestQueueAssets is QueuesTest {
    function testQueueAssetsDeposit() public {
        vm.prank(AUTH);
        vm.expectEmit();
        emit ISnapshotQueue.QueueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, IS_DEPOSIT);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, IS_DEPOSIT);

        (,, uint32 queuedAssetCounter,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (uint128 deposits, uint128 withdrawals) = snapshotQueue.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, AMOUNT);
        assertEq(withdrawals, 0);
    }

    function testQueueAssetsWithdrawal() public {
        vm.prank(AUTH);
        vm.expectEmit();
        emit ISnapshotQueue.QueueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, !IS_DEPOSIT);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, !IS_DEPOSIT);

        (,, uint32 queuedAssetCounter,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (uint128 deposits, uint128 withdrawals) = snapshotQueue.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, 0);
        assertEq(withdrawals, AMOUNT);
    }

    function testQueueAssetsZeroIsNoOp() public {
        vm.prank(AUTH);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, 0, IS_DEPOSIT);

        (,, uint32 queuedAssetCounter,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
    }

    function testQueueAssetsTwiceAccumulates() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, IS_DEPOSIT);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, IS_DEPOSIT);

        (,, uint32 queuedAssetCounter,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (uint128 deposits,) = snapshotQueue.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, AMOUNT * 2);
    }

    function testQueueAssetsDepositAndWithdrawalSameAsset() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, IS_DEPOSIT);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, !IS_DEPOSIT);

        (,, uint32 queuedAssetCounter,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (uint128 deposits, uint128 withdrawals) = snapshotQueue.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, AMOUNT);
        assertEq(withdrawals, AMOUNT);
    }

    function testQueueAssetsDifferentAssets() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, IS_DEPOSIT);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_6909_1, AMOUNT, IS_DEPOSIT);

        (,, uint32 queuedAssetCounter,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 2);
    }
}

contract QueuesTestQueueShares is QueuesTest {
    function testIssue() public {
        vm.prank(AUTH);
        vm.expectEmit();
        emit ISnapshotQueue.QueueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, true);
    }

    function testQueueSharesZeroIsNoOp() public {
        vm.prank(AUTH);
        vm.recordLogs();
        snapshotQueue.queueShares(POOL_A, SC_1, 0, IS_ISSUANCE);
        assertEq(vm.getRecordedLogs().length, 0);

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, 0);
        assertEq(isPositive, false);
    }

    function testIssueTwice() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT * 2);
        assertEq(isPositive, true);
    }

    function testRevoke() public {
        vm.prank(AUTH);
        vm.expectEmit();
        emit ISnapshotQueue.QueueShares(POOL_A, SC_1, AMOUNT, !IS_ISSUANCE);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, !IS_ISSUANCE);

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, false);
    }

    function testRevokeTwice() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, !IS_ISSUANCE);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, !IS_ISSUANCE);

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT * 2);
        assertEq(isPositive, false);
    }

    function testIssueAndThenRevokeSameAmount() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, !IS_ISSUANCE);

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, 0);
        assertEq(isPositive, false);
    }

    function testIssueAndThenRevokeAndThenIssueSameAmount() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, !IS_ISSUANCE);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, true);
    }

    function testIssueAndThenRevokeWithLessAmount() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT / 4, !IS_ISSUANCE);

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT * 3 / 4);
        assertEq(isPositive, true);
    }

    function testIssueAndThenRevokeWithMoreAmount() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);
        snapshotQueue.queueShares(POOL_A, SC_1, 2 * AMOUNT, !IS_ISSUANCE);

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, false);
    }

    function testRevokeAndThenIssueAndThenRevokeSameAmount() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, !IS_ISSUANCE);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, !IS_ISSUANCE);

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, false);
    }

    function testRevokeAndThenIssueSameAmount() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, !IS_ISSUANCE);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, 0);
        assertEq(isPositive, false);
    }

    function testRevokeAndThenIssueWithLessAmount() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT / 4, !IS_ISSUANCE);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT * 3 / 4);
        assertEq(isPositive, true);
    }

    function testRevokeAndThenIssueWithMoreAmount() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueShares(POOL_A, SC_1, 2 * AMOUNT, !IS_ISSUANCE);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, false);
    }
}

contract QueuesTestFlushAssets is QueuesTest {
    function testFlushEmptyQueue() public {
        vm.prank(AUTH);
        ISpokeMessageSender.UpdateData memory data = snapshotQueue.flushAssets(POOL_A, SC_1, ASSET_20);

        assertEq(data.netAmount, 0);
        assertEq(data.isIncrease, false);
        assertEq(data.isSnapshot, true);
        assertEq(data.nonce, 0);

        (,,, uint64 nonce) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(nonce, 1);
    }

    function testFlushWithMoreDepositAmount() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT * 3, IS_DEPOSIT);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, !IS_DEPOSIT);

        vm.expectEmit();
        emit ISnapshotQueue.SubmitQueuedAssets(
            POOL_A, SC_1, ASSET_20, ISpokeMessageSender.UpdateData(AMOUNT * 2, IS_DEPOSIT, IS_SNAPSHOT, 0)
        );
        ISpokeMessageSender.UpdateData memory data = snapshotQueue.flushAssets(POOL_A, SC_1, ASSET_20);

        assertEq(data.netAmount, AMOUNT * 2);
        assertEq(data.isIncrease, true);
        assertEq(data.isSnapshot, true);

        (uint128 deposits, uint128 withdrawals) = snapshotQueue.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, 0);
        assertEq(withdrawals, 0);

        (,, uint32 queuedAssetCounter, uint64 nonce) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
        assertEq(nonce, 1);
    }

    function testFlushWithMoreWithdrawAmount() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, IS_DEPOSIT);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT * 3, !IS_DEPOSIT);

        ISpokeMessageSender.UpdateData memory data = snapshotQueue.flushAssets(POOL_A, SC_1, ASSET_20);

        assertEq(data.netAmount, AMOUNT * 2);
        assertEq(data.isIncrease, false);
        assertEq(data.isSnapshot, true);

        (,, uint32 queuedAssetCounter, uint64 nonce) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
        assertEq(nonce, 1);
    }

    function testFlushWithSameAmount() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, IS_DEPOSIT);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, !IS_DEPOSIT);

        ISpokeMessageSender.UpdateData memory data = snapshotQueue.flushAssets(POOL_A, SC_1, ASSET_20);

        assertEq(data.netAmount, 0);
        assertEq(data.isIncrease, false);
        assertEq(data.isSnapshot, true);

        (uint128 deposits, uint128 withdrawals) = snapshotQueue.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, 0);
        assertEq(withdrawals, 0);
    }

    function testFlushWithDifferentAssetsPending() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, IS_DEPOSIT);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_6909_1, AMOUNT, IS_DEPOSIT);

        ISpokeMessageSender.UpdateData memory data = snapshotQueue.flushAssets(POOL_A, SC_1, ASSET_20);

        // Another asset is still queued, so the update is not a snapshot.
        assertEq(data.isSnapshot, false);

        (,, uint32 queuedAssetCounter, uint64 nonce) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);
        assertEq(nonce, 1);
    }

    function testFlushWithQueuedSharesPending() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, IS_DEPOSIT);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);

        ISpokeMessageSender.UpdateData memory data = snapshotQueue.flushAssets(POOL_A, SC_1, ASSET_20);

        // A share delta is still queued, so the update is not a snapshot.
        assertEq(data.isSnapshot, false);
    }

    function testFlushTwiceIncrementsNonce() public {
        vm.startPrank(AUTH);
        snapshotQueue.flushAssets(POOL_A, SC_1, ASSET_20);
        snapshotQueue.flushAssets(POOL_A, SC_1, ASSET_20);

        (,,, uint64 nonce) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(nonce, 2);
    }
}

contract QueuesTestFlushShares is QueuesTest {
    function testFlushEmptyQueue() public {
        vm.prank(AUTH);
        ISpokeMessageSender.UpdateData memory data = snapshotQueue.flushShares(POOL_A, SC_1);

        assertEq(data.netAmount, 0);
        assertEq(data.isIncrease, false);
        assertEq(data.isSnapshot, true);
        assertEq(data.nonce, 0);

        (,,, uint64 nonce) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(nonce, 1);
    }

    function testFlushWithDeltaPositive() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);

        vm.expectEmit();
        emit ISnapshotQueue.SubmitQueuedShares(
            POOL_A, SC_1, ISpokeMessageSender.UpdateData(AMOUNT, IS_ISSUANCE, IS_SNAPSHOT, 0)
        );
        ISpokeMessageSender.UpdateData memory data = snapshotQueue.flushShares(POOL_A, SC_1);

        assertEq(data.netAmount, AMOUNT);
        assertEq(data.isIncrease, true);
        assertEq(data.isSnapshot, true);

        (uint128 delta, bool isPositive,, uint64 nonce) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, 0);
        assertEq(isPositive, false);
        assertEq(nonce, 1);
    }

    function testFlushWithDeltaNegative() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, !IS_ISSUANCE);

        ISpokeMessageSender.UpdateData memory data = snapshotQueue.flushShares(POOL_A, SC_1);

        assertEq(data.netAmount, AMOUNT);
        assertEq(data.isIncrease, false);
        assertEq(data.isSnapshot, true);
    }

    function testFlushWithQueuedAssetsPending() public {
        vm.startPrank(AUTH);
        snapshotQueue.queueAssets(POOL_A, SC_1, ASSET_20, AMOUNT, IS_DEPOSIT);
        snapshotQueue.queueShares(POOL_A, SC_1, AMOUNT, IS_ISSUANCE);

        ISpokeMessageSender.UpdateData memory data = snapshotQueue.flushShares(POOL_A, SC_1);

        // An asset is still queued, so the update is not a snapshot.
        assertEq(data.isSnapshot, false);
    }

    function testFlushTwiceIncrementsNonce() public {
        vm.startPrank(AUTH);
        snapshotQueue.flushShares(POOL_A, SC_1);
        snapshotQueue.flushShares(POOL_A, SC_1);

        (,,, uint64 nonce) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(nonce, 2);
    }

    function testAssetAndShareFlushesShareNonce() public {
        vm.startPrank(AUTH);
        snapshotQueue.flushAssets(POOL_A, SC_1, ASSET_20);
        ISpokeMessageSender.UpdateData memory data = snapshotQueue.flushShares(POOL_A, SC_1);

        assertEq(data.nonce, 1);

        (,,, uint64 nonce) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(nonce, 2);
    }
}
