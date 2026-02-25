// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";

import "forge-std/Test.sol";

import {SubsidyManager, ISubsidyManager} from "../../../src/utils/SubsidyManager.sol";
import {IRefundEscrowFactory, IRefundEscrow} from "../../../src/utils/RefundEscrowFactory.sol";

contract IsContract {}

contract SubsidyManagerTest is Test {
    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");
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

    function testErrRefundEscrowNotDeployed() public {
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.get.selector, POOL_A),
            abi.encode(address(0))
        );

        vm.prank(AUTH);
        vm.expectRevert(ISubsidyManager.RefundEscrowNotDeployed.selector);
        subsidyManager.withdrawAll(POOL_A, RECEIVER);
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

contract SubsidyManagerTestTrustedCall is SubsidyManagerTest {
    using CastLib for *;

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        subsidyManager.trustedCall(POOL_A, SC_PLACEHOLDER, "");
    }

    function testErrRefundEscrowNotDeployed() public {
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.get.selector, POOL_A),
            abi.encode(address(0))
        );

        vm.prank(AUTH);
        vm.expectRevert(ISubsidyManager.RefundEscrowNotDeployed.selector);
        subsidyManager.trustedCall(POOL_A, SC_PLACEHOLDER, abi.encode(RECEIVER.toBytes32(), SUBSIDY_AMOUNT));
    }

    function testErrNotEnoughToWithdraw() public {
        address emptyRefund = address(new IsContract());
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.get.selector, POOL_A),
            abi.encode(emptyRefund)
        );

        vm.prank(AUTH);
        vm.expectRevert(ISubsidyManager.NotEnoughToWithdraw.selector);
        subsidyManager.trustedCall(POOL_A, SC_PLACEHOLDER, abi.encode(RECEIVER.toBytes32(), SUBSIDY_AMOUNT));
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
        vm.expectEmit();
        emit ISubsidyManager.WithdrawSubsidy(POOL_A, RECEIVER, SUBSIDY_AMOUNT);
        subsidyManager.trustedCall(POOL_A, SC_PLACEHOLDER, abi.encode(RECEIVER.toBytes32(), SUBSIDY_AMOUNT));
    }
}
