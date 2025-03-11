// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {ERC6909} from "src/misc/ERC6909.sol";

import {Escrow} from "src/vaults/Escrow.sol";
import {IPerPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";

import "test/vaults/BaseTest.sol";

contract EscrowTest is BaseTest {
    function testApproveMax() public {
        Escrow escrow = new Escrow(address(this));
        address spender = address(0x2);
        assertEq(erc20.allowance(address(escrow), spender), 0);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.approveMax(address(erc20), spender);

        escrow.approveMax(address(erc20), spender);
        assertEq(erc20.allowance(address(escrow), spender), type(uint256).max);
    }

    function testUnapprove() public {
        Escrow escrow = new Escrow(address(this));
        address spender = address(0x2);
        escrow.approveMax(address(erc20), spender);
        assertEq(erc20.allowance(address(escrow), spender), type(uint256).max);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.unapprove(address(erc20), spender);

        escrow.unapprove(address(erc20), spender);
        assertEq(erc20.allowance(address(escrow), spender), 0);
    }

    // -------------------------------------------------
    // Tests for PerPoolEscrow
    // -------------------------------------------------
    uint256 constant TEST_TOKEN_ID = 0; // We'll treat this as an ERC20 scenario
<<<<<<< HEAD
    uint64  constant TEST_POOL_ID  = 456;
    uint16  constant TEST_SC_ID    = 789;
=======
    uint64 constant TEST_POOL_ID = 456;
    bytes16 constant TEST_SC_ID = bytes16(0);
>>>>>>> ce45ccd (fix: docs, logic to act as reservance)

    function testPendingDepositIncrease() public {
        Escrow escrow = new Escrow(address(this));

        vm.prank(randomUser);
        vm.expectRevert("Auth/not-authorized");
        escrow.pendingDepositIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 100);

        escrow.pendingDepositIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 100);
    }

    function testPendingDepositDecrease() public {
        Escrow escrow = new Escrow(address(this));

        escrow.pendingDepositIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 200);

        vm.prank(randomUser);
        vm.expectRevert("Auth/not-authorized");
        escrow.pendingDepositDecrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 50);

        escrow.pendingDepositDecrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 50);

        vm.expectRevert(IPerPoolEscrow.InsufficientPendingDeposit.selector);
        escrow.pendingDepositDecrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 300);
    }

    function testDeposit() public {
        Escrow escrow = new Escrow(address(this));
        escrow.pendingDepositIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 500);

        erc20.mint(address(escrow), 300);

        vm.expectRevert(IPerPoolEscrow.InsufficientDeposit.selector);
        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 500);

        vm.expectRevert(IPerPoolEscrow.InsufficientPendingDeposit.selector);
        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 600);

        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 300);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID),
            300,
            "holdings should be 300 after deposit"
        );

        vm.expectRevert(IPerPoolEscrow.InsufficientDeposit.selector);
        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 200);

        erc20.mint(address(escrow), 200);

        vm.expectRevert(IPerPoolEscrow.InsufficientPendingDeposit.selector);
        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 201);

        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 200);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID),
            500,
            "holdings should be 500 after deposit"
        );
    }

    function testReserveIncrease() public {
        Escrow escrow = new Escrow(address(this));

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.reserveIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 100);

        escrow.reserveIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 100);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID),
            0,
            "Still zero, nothing is in holdings"
        );

        escrow.pendingDepositIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 300);
        erc20.mint(address(escrow), 300);
        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 100);

        assertEq(escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID), 0, "100 - 100 = 0");

        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 200);
        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID), 200, "100 - 100 = 0"
        );
    }

    function testPendingWithdrawDecrease() public {
        Escrow escrow = new Escrow(address(this));

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.reserveIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 100);

        escrow.reserveIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 100);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID),
            0,
            "Still zero, nothing is in holdings"
        );

        escrow.pendingDepositIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 300);
        erc20.mint(address(escrow), 300);
        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 100);

        assertEq(escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID), 0, "100 - 100 = 0");

        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 200);
        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID), 200, "300 - 100 = 200"
        );

        vm.expectRevert(IPerPoolEscrow.InsufficientReservedAmount.selector);
        escrow.reserveDecrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 200);

        escrow.reserveDecrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 100);
        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID), 300, "300 - 0 = 300"
        );
    }

    function testWithdraw() public {
        Escrow escrow = new Escrow(address(this));

        erc20.mint(address(escrow), 1000);
        escrow.pendingDepositIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 1000);
        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 1000);
        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID),
            1000,
            "initial holdings should be 1000"
        );

        escrow.reserveIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 500);

        vm.expectRevert(IPerPoolEscrow.InsufficientBalance.selector);
        escrow.withdraw(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 600);

        escrow.withdraw(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 500);

        assertEq(escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID), 0);
    }

    function testAvailableBalanceOf() public {
        Escrow escrow = new Escrow(address(this));

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID),
            0,
            "Default available balance should be zero"
        );

        erc20.mint(address(escrow), 500);
        escrow.pendingDepositIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 500);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID),
            0,
            "Available balance needs deposit first."
        );

        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 500);

        escrow.reserveIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 200);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID),
            300,
            "Should be 300 after reserve increase"
        );

        escrow.reserveIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 300);
        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID),
            0,
            "Should be zero if pendingWithdraw >= holdings"
        );
    }
}
