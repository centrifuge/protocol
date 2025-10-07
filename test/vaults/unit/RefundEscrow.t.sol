// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {RefundEscrow, IRefundEscrow} from "../../../src/vaults/RefundEscrow.sol";

import "forge-std/Test.sol";

contract NoReceivable {}

contract RefundEscrowTest is Test {
    address immutable ANY = makeAddr("any");
    address immutable AUTH = makeAddr("auth");
    address immutable RECEIVER = makeAddr("receiver");
    address immutable NO_RECEIVER = address(new NoReceivable());

    RefundEscrow escrow;

    function setUp() external {
        escrow = new RefundEscrow();
        IAuth(address(escrow)).rely(AUTH); // Mimic controller behavior
        IAuth(address(escrow)).deny(address(this)); // Mimic factory behavior

        vm.deal(ANY, 1 ether);
        vm.deal(AUTH, 1 ether);
    }
}

contract RefundEscrowTestReceive is RefundEscrowTest {
    function testErrNotAuthorized() external {
        (bool success,) = address(escrow).call{value: 100}("");
        assert(success);
    }
}

contract RefundEscrowTestDepositFunds is RefundEscrowTest {
    function testErrNotAuthorized() external {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.depositFunds{value: 100}();
    }

    function testDepositFunds() external {
        vm.prank(AUTH);
        escrow.depositFunds{value: 100}();

        assertEq(address(escrow).balance, 100);
    }
}

contract RefundEscrowTestWithdrawFunds is RefundEscrowTest {
    function testErrNotAuthorized() external {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.withdrawFunds(RECEIVER, 100);
    }

    function testErrCannotWithdraw() external {
        vm.prank(AUTH);
        escrow.depositFunds{value: 100}();

        vm.prank(AUTH);
        vm.expectRevert(IRefundEscrow.CannotWithdraw.selector);
        escrow.withdrawFunds(NO_RECEIVER, 50);
    }

    function testWithdrawFunds() external {
        vm.prank(AUTH);
        escrow.depositFunds{value: 100}();

        vm.prank(AUTH);
        escrow.withdrawFunds(RECEIVER, 50);

        assertEq(address(escrow).balance, 50);
        assertEq(address(RECEIVER).balance, 50);
    }
}
