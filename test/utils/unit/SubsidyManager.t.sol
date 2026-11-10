// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";

import "forge-std/Test.sol";

import {SubsidyManager, ISubsidyManager} from "../../../src/utils/SubsidyManager.sol";
import {RefundEscrowFactory, IRefundEscrowFactory, IRefundEscrow} from "../../../src/utils/RefundEscrowFactory.sol";

contract IsContract {}

contract SubsidyManagerTest is Test {
    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");
    address immutable ENVOY = makeAddr("ENVOY");
    uint256 constant SUBSIDY_AMOUNT = 1 ether;
    address immutable RECEIVER = makeAddr("RECEIVER");

    IRefundEscrowFactory refundEscrowFactory = IRefundEscrowFactory(address(new IsContract()));
    IRefundEscrow refundEscrow = IRefundEscrow(address(new IsContract()));

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_PLACEHOLDER = ShareClassId.wrap(bytes16("any"));

    SubsidyManager subsidyManager = new SubsidyManager(refundEscrowFactory, AUTH);

    function setUp() public virtual {
        vm.deal(ANY, 1 ether);
        vm.deal(address(refundEscrow), 1 ether);
        vm.prank(AUTH);
        subsidyManager.file("envoy", ENVOY);
    }

    function testConstructor() public view {
        assertEq(address(subsidyManager.refundEscrowFactory()), address(refundEscrowFactory));
    }
}

contract SubsidyManagerTestFile is SubsidyManagerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        subsidyManager.file("spoke", address(1));
    }

    function testErrFileUnrecognizedParam() public {
        vm.prank(AUTH);
        vm.expectRevert(ISubsidyManager.FileUnrecognizedParam.selector);
        subsidyManager.file("random", address(1));
    }

    function testFile() public {
        vm.startPrank(AUTH);

        vm.expectEmit();
        emit ISubsidyManager.File("refundEscrowFactory", address(11));
        subsidyManager.file("refundEscrowFactory", address(11));
        assertEq(address(subsidyManager.refundEscrowFactory()), address(11));

        vm.stopPrank();
    }
}

contract SubsidyManagerTestDepositSubsidy is SubsidyManagerTest {
    function testDepositSubsidyNewEscrow() public {
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.get.selector, POOL_A),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.newEscrow.selector, POOL_A),
            abi.encode(refundEscrow)
        );
        vm.mockCall(
            address(refundEscrow),
            SUBSIDY_AMOUNT,
            abi.encodeWithSelector(refundEscrow.depositFunds.selector),
            abi.encode()
        );

        vm.prank(ANY);
        vm.expectCall(
            address(refundEscrow), SUBSIDY_AMOUNT, abi.encodeWithSelector(IRefundEscrow.depositFunds.selector)
        );
        vm.expectEmit();
        emit ISubsidyManager.DepositSubsidy(POOL_A, ANY, SUBSIDY_AMOUNT);
        subsidyManager.deposit{value: SUBSIDY_AMOUNT}(POOL_A);
    }

    function testDepositSubsidyExistingEscrow() public {
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.get.selector, POOL_A),
            abi.encode(refundEscrow)
        );
        vm.mockCall(
            address(refundEscrow),
            SUBSIDY_AMOUNT,
            abi.encodeWithSelector(refundEscrow.depositFunds.selector),
            abi.encode()
        );

        vm.prank(ANY);
        vm.expectCall(
            address(refundEscrow), SUBSIDY_AMOUNT, abi.encodeWithSelector(IRefundEscrow.depositFunds.selector)
        );
        vm.expectEmit();
        emit ISubsidyManager.DepositSubsidy(POOL_A, ANY, SUBSIDY_AMOUNT);
        subsidyManager.deposit{value: SUBSIDY_AMOUNT}(POOL_A);
    }
}

contract SubsidyManagerTestWithdrawSubsidy is SubsidyManagerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        subsidyManager.withdrawAll(POOL_A, RECEIVER);
    }

    function testWithdrawAllNoEscrowReturnsZero() public {
        // get() returns the deterministic escrow address even before deployment (no code yet).
        address undeployed = makeAddr("undeployedEscrow");
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.get.selector, POOL_A),
            abi.encode(undeployed)
        );

        // Returns zero funds instead of reverting, so the caller's message goes out unpaid.
        vm.prank(AUTH);
        (address refund, uint256 value) = subsidyManager.withdrawAll(POOL_A, RECEIVER);

        assertEq(refund, undeployed);
        assertEq(value, 0);
    }

    function testWithdrawSubsidy() public {
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.get.selector, POOL_A),
            abi.encode(refundEscrow)
        );
        vm.mockCall(
            address(refundEscrow),
            abi.encodeWithSelector(refundEscrow.withdrawFunds.selector, RECEIVER, SUBSIDY_AMOUNT),
            abi.encode()
        );

        vm.prank(AUTH);
        (address refund, uint256 value) = subsidyManager.withdrawAll(POOL_A, RECEIVER);

        assertEq(refund, address(refundEscrow));
        assertEq(value, SUBSIDY_AMOUNT);
    }
}

contract SubsidyManagerTestFromHub is SubsidyManagerTest {
    using CastLib for *;

    function testErrNotEnvoy() public {
        vm.prank(ANY);
        vm.expectRevert(ISubsidyManager.NotEnvoy.selector);
        subsidyManager.fromHub(POOL_A, "");
    }

    function testErrUnexpectedValue() public {
        vm.deal(ENVOY, 1 ether);
        vm.prank(ENVOY);
        vm.expectRevert(ISubsidyManager.UnexpectedValue.selector);
        subsidyManager.fromHub{value: 1}(POOL_A, abi.encode(RECEIVER.toBytes32(), SUBSIDY_AMOUNT));
    }

    function testErrRefundEscrowNotDeployed() public {
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.get.selector, POOL_A),
            abi.encode(address(0))
        );

        vm.prank(ENVOY);
        vm.expectRevert(ISubsidyManager.RefundEscrowNotDeployed.selector);
        subsidyManager.fromHub(POOL_A, abi.encode(RECEIVER.toBytes32(), SUBSIDY_AMOUNT));
    }

    function testErrNotEnoughToWithdraw() public {
        address emptyRefund = address(new IsContract());
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.get.selector, POOL_A),
            abi.encode(emptyRefund)
        );

        vm.prank(ENVOY);
        vm.expectRevert(ISubsidyManager.NotEnoughToWithdraw.selector);
        subsidyManager.fromHub(POOL_A, abi.encode(RECEIVER.toBytes32(), SUBSIDY_AMOUNT));
    }

    function testWithdrawSubsidy() public {
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.get.selector, POOL_A),
            abi.encode(refundEscrow)
        );
        vm.mockCall(
            address(refundEscrow),
            abi.encodeWithSelector(refundEscrow.withdrawFunds.selector, RECEIVER, SUBSIDY_AMOUNT),
            abi.encode()
        );

        vm.prank(ENVOY);
        vm.expectEmit();
        emit ISubsidyManager.WithdrawSubsidy(POOL_A, RECEIVER, SUBSIDY_AMOUNT);
        subsidyManager.fromHub(POOL_A, abi.encode(RECEIVER.toBytes32(), SUBSIDY_AMOUNT));
    }
}

/// @dev `withdrawAll` against a real factory and escrow, since the router relies on the escrow being drained
///      in full and on an undeployed one answering zero rather than reverting
contract SubsidyManagerTestWithdrawAll is Test {
    address immutable ANY = makeAddr("ANY");
    address immutable ROUTER = makeAddr("ROUTER");
    address immutable RECEIVER = makeAddr("RECEIVER");

    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);

    RefundEscrowFactory factory;
    SubsidyManager subsidyManager;

    function setUp() public {
        factory = new RefundEscrowFactory(address(this));
        subsidyManager = new SubsidyManager(factory, address(this));

        factory.file("controller", address(subsidyManager));
        factory.rely(address(subsidyManager));
        subsidyManager.rely(ROUTER);

        vm.deal(ANY, 10 ether);
    }

    function testDrainsTheWholeBalance() public {
        vm.prank(ANY);
        subsidyManager.deposit{value: 1 ether}(POOL_A);
        vm.prank(ANY);
        subsidyManager.deposit{value: 0.5 ether}(POOL_A);

        address escrow = address(factory.get(POOL_A));

        vm.prank(ROUTER);
        (address refund, uint256 value) = subsidyManager.withdrawAll(POOL_A, RECEIVER);

        assertEq(refund, escrow);
        assertEq(value, 1.5 ether);
        assertEq(RECEIVER.balance, 1.5 ether);
        assertEq(escrow.balance, 0);
    }

    function testASecondCallFindsNothing() public {
        vm.prank(ANY);
        subsidyManager.deposit{value: 1 ether}(POOL_A);

        vm.startPrank(ROUTER);
        subsidyManager.withdrawAll(POOL_A, RECEIVER);
        (, uint256 value) = subsidyManager.withdrawAll(POOL_A, RECEIVER);
        vm.stopPrank();

        assertEq(value, 0);
        assertEq(RECEIVER.balance, 1 ether);
    }

    function testLeavesOtherPoolsAlone() public {
        vm.startPrank(ANY);
        subsidyManager.deposit{value: 1 ether}(POOL_A);
        subsidyManager.deposit{value: 2 ether}(POOL_B);
        vm.stopPrank();

        vm.prank(ROUTER);
        subsidyManager.withdrawAll(POOL_A, RECEIVER);

        assertEq(address(factory.get(POOL_B)).balance, 2 ether);
    }

    function testUndeployedEscrowAnswersZero() public {
        vm.prank(ROUTER);
        (address refund, uint256 value) = subsidyManager.withdrawAll(POOL_A, RECEIVER);

        assertEq(refund, address(factory.get(POOL_A)));
        assertEq(refund.code.length, 0);
        assertEq(value, 0);
    }

    function testRevertsWhenTheReceiverRejectsFunds() public {
        vm.prank(ANY);
        subsidyManager.deposit{value: 1 ether}(POOL_A);

        address rejecting = address(new IsContract());

        vm.prank(ROUTER);
        vm.expectRevert(IRefundEscrow.CannotWithdraw.selector);
        subsidyManager.withdrawAll(POOL_A, rejecting);
    }

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        subsidyManager.withdrawAll(POOL_A, RECEIVER);
    }
}
