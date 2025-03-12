// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {ERC6909} from "src/misc/ERC6909.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

import {Escrow} from "src/vaults/Escrow.sol";
import {IEscrow, IPerPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";

import "test/vaults/BaseTest.sol";

contract EscrowTest is BaseTest {
    address constant spender = address(0x2);

    function testApproveMax() public {
        Escrow escrow = new Escrow(address(this));
        assertEq(erc20.allowance(address(escrow), spender), 0);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.approveMax(address(erc20), spender);

        vm.expectEmit();
        emit IEscrow.Approve(address(erc20), spender, type(uint256).max);
        escrow.approveMax(address(erc20), spender);
        assertEq(erc20.allowance(address(escrow), spender), type(uint256).max);
    }

    function testUnapprove() public {
        assertEq(address(erc20), address(erc20));
        Escrow escrow = new Escrow(address(this));
        escrow.approveMax(address(erc20), spender);
        assertEq(erc20.allowance(address(escrow), spender), type(uint256).max);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.unapprove(address(erc20), spender);

        vm.expectEmit();
        emit IEscrow.Approve(address(erc20), spender, 0);
        escrow.unapprove(address(erc20), spender);
        assertEq(erc20.allowance(address(escrow), spender), 0);
    }

    // -------------------------------------------------
    // Tests for PerPoolEscrow
    // -------------------------------------------------
    uint256 constant TEST_erc20Addr_ID = 0; // We'll treat this as an ERC20 scenario
    uint64  constant TEST_POOL_ID  = 456;
    bytes16 constant TEST_SC_ID = bytes16(0);

    function testPendingDepositIncrease() public {
        Escrow escrow = new Escrow(address(this));

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.pendingDepositIncrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 100);

        vm.expectEmit();
        emit IPerPoolEscrow.PendingDeposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 100);
        escrow.pendingDepositIncrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 100);
    }

    function testPendingDepositDecrease() public {
        Escrow escrow = new Escrow(address(this));

        escrow.pendingDepositIncrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 200);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.pendingDepositDecrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 50);

        vm.expectEmit();
        emit IPerPoolEscrow.PendingDeposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 150);
        escrow.pendingDepositDecrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 50);

        vm.expectRevert(IPerPoolEscrow.InsufficientPendingDeposit.selector);
        escrow.pendingDepositDecrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 300);
    }

    function testDeposit() public {
        Escrow escrow = new Escrow(address(this));
        escrow.pendingDepositIncrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 500);

        erc20.mint(address(escrow), 300);

        vm.expectRevert(IPerPoolEscrow.InsufficientDeposit.selector);
        escrow.deposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 500);

        vm.expectRevert(IPerPoolEscrow.InsufficientPendingDeposit.selector);
        escrow.deposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 600);

        vm.expectEmit();
        emit IPerPoolEscrow.Deposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 300);
        emit IPerPoolEscrow.PendingDeposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 200);
        escrow.deposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 300);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID),
            300,
            "holdings should be 300 after deposit"
        );

        vm.expectRevert(IPerPoolEscrow.InsufficientDeposit.selector);
        escrow.deposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 200);

        erc20.mint(address(escrow), 200);

        vm.expectRevert(IPerPoolEscrow.InsufficientPendingDeposit.selector);
        escrow.deposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 201);

        vm.expectEmit();
        emit IPerPoolEscrow.Deposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 200);
        emit IPerPoolEscrow.PendingDeposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 0);
        escrow.deposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 200);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID),
            500,
            "holdings should be 500 after deposit"
        );
    }

    function testReserveIncrease() public {
        Escrow escrow = new Escrow(address(this));

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.reserveIncrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 100);

        vm.expectEmit();
        emit IPerPoolEscrow.Reserve(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 100);
        escrow.reserveIncrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 100);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID),
            0,
            "Still zero, nothing is in holdings"
        );

        escrow.pendingDepositIncrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 300);
        erc20.mint(address(escrow), 300);
        escrow.deposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 100);

        assertEq(escrow.availableBalanceOf(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID), 0, "100 - 100 = 0");

        escrow.deposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 200);
        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID), 200, "300 - 100 = 200"
        );
    }

    function testPendingWithdrawDecrease() public {
        Escrow escrow = new Escrow(address(this));

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.reserveIncrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 100);

        escrow.reserveIncrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 100);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID),
            0,
            "Still zero, nothing is in holdings"
        );

        escrow.pendingDepositIncrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 300);
        erc20.mint(address(escrow), 300);
        escrow.deposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 100);

        assertEq(escrow.availableBalanceOf(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID), 0, "100 - 100 = 0");

        escrow.deposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 200);
        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID), 200, "300 - 100 = 200"
        );

        vm.expectRevert(IPerPoolEscrow.InsufficientReservedAmount.selector);
        escrow.reserveDecrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 200);

        vm.expectEmit();
        emit IPerPoolEscrow.Reserve(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 0);
        escrow.reserveDecrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 100);
        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID), 300, "300 - 0 = 300"
        );
    }

    function testWithdraw() public {
        Escrow escrow = new Escrow(address(this));

        erc20.mint(address(escrow), 1000);
        escrow.pendingDepositIncrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 1000);
        escrow.deposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 1000);
        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID),
            1000,
            "initial holdings should be 1000"
        );

        escrow.reserveIncrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 500);

        vm.expectRevert(IPerPoolEscrow.InsufficientBalance.selector);
        escrow.withdraw(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 600);

        vm.expectEmit();
        emit IPerPoolEscrow.Withdraw(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 500);
        escrow.withdraw(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 500);

        assertEq(escrow.availableBalanceOf(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID), 0);
    }

    function testAvailableBalanceOf() public {
        Escrow escrow = new Escrow(address(this));

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID),
            0,
            "Default available balance should be zero"
        );

        erc20.mint(address(escrow), 500);
        escrow.pendingDepositIncrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 500);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID),
            0,
            "Available balance needs deposit first."
        );

        escrow.deposit(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 500);

        escrow.reserveIncrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 200);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID),
            300,
            "Should be 300 after reserve increase"
        );

        escrow.reserveIncrease(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID, 300);
        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_erc20Addr_ID, TEST_POOL_ID, TEST_SC_ID),
            0,
            "Should be zero if pendingWithdraw >= holdings"
        );
    }
}
