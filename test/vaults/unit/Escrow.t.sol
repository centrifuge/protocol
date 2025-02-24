// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Escrow} from "src/vaults/Escrow.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import "test/vaults/BaseTest.sol";
import {ERC6909} from "../../../src/misc/ERC6909.sol";

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
    // New tests for PerPoolEscrow / updated deposit/withdraw
    // -------------------------------------------------
    uint256 constant TEST_TOKEN_ID = 0; // We'll treat this as an ERC20 scenario
    uint64  constant TEST_POOL_ID  = 456;
    uint16  constant TEST_SC_ID    = 789;

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

        vm.expectRevert("Escrow/insufficient-pending-deposits");
        escrow.pendingDepositDecrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 300);
    }

    function testDeposit() public {
        Escrow escrow = new Escrow(address(this));
        escrow.pendingDepositIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 500);

        erc20.mint(address(escrow), 300);

        vm.expectRevert("Escrow/insufficient-balance-increase");
        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 500);

        vm.expectRevert("Escrow/insufficient-pending-deposits");
        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 600);

        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 300);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID),
            300,
            "holdings should be 300 after deposit"
        );

        vm.expectRevert("Escrow/insufficient-balance-increase");
        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 200);

        erc20.mint(address(escrow), 200);

        vm.expectRevert("Escrow/insufficient-pending-deposits");
        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 201);

        escrow.deposit(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 200);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID),
            500,
            "holdings should be 500 after deposit"
        );
    }

    function testPendingWithdrawIncrease() public {
        Escrow escrow = new Escrow(address(this));

        vm.prank(randomUser);
        vm.expectRevert("Auth/not-authorized");
        escrow.pendingWithdrawIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 100);

        escrow.pendingWithdrawIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 100);
    }

    function testPendingWithdrawDecrease() public {
        Escrow escrow = new Escrow(address(this));

        escrow.pendingWithdrawIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 200);

        vm.prank(randomUser);
        vm.expectRevert("Auth/not-authorized");
        escrow.pendingWithdrawDecrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 50);

        escrow.pendingWithdrawDecrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 50);

        vm.expectRevert("Escrow/insufficient-pending-withdraws");
        escrow.pendingWithdrawDecrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 300);
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

        escrow.pendingWithdrawIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 500);

        vm.expectRevert("Escrow/insufficient-funds");
        escrow.withdraw(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 600);

        escrow.approveMax(address(erc20), address(this)); // let test contract pull from escrow
        erc20.transferFrom(address(escrow), address(this), 400);

        escrow.withdraw(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 400);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID),
            600 - 500, // still have 500 pending withdraw => 100 left available
            "available balance should reflect updated holdings minus pendingWithdraw"
        );
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

        escrow.pendingWithdrawIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 200);

        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID),
            300,
            "Should be 300 after pending withdraw"
        );

        escrow.pendingWithdrawIncrease(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID, 400);
        assertEq(
            escrow.availableBalanceOf(address(erc20), TEST_TOKEN_ID, TEST_POOL_ID, TEST_SC_ID),
            0,
            "Should be zero if pendingWithdraw > holdings"
        );
    }
}
