// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Accounting} from "src/Accounting.sol";
import {IAccounting} from "src/interfaces/IAccounting.sol";
import {IAuth} from "src/interfaces/IAuth.sol";
import {AccountId, accountId} from "src/types/AccountId.sol";
import {PoolId} from "src/types/PoolId.sol";

enum AccountType {
    ASSET,
    EQUITY,
    LOSS,
    GAIN
}

PoolId constant POOL_A = PoolId.wrap(1);
PoolId constant POOL_B = PoolId.wrap(2);

contract AccountingTest is Test {
    AccountId immutable CASH_ACCOUNT = accountId(1, uint8(AccountType.ASSET));
    AccountId immutable BOND1_INVESTMENT_ACCOUNT = accountId(101, uint8(AccountType.ASSET));
    AccountId immutable FEES_EXPENSE_ACCOUNT = accountId(401, uint8(AccountType.ASSET));
    AccountId immutable FEES_PAYABLE_ACCOUNT = accountId(201, uint8(AccountType.LOSS));
    AccountId immutable EQUITY_ACCOUNT = accountId(301, uint8(AccountType.EQUITY));
    AccountId immutable GAIN_ACCOUNT = accountId(302, uint8(AccountType.GAIN));
    AccountId immutable NON_INITIALIZED_ACCOUNT = accountId(999, uint8(AccountType.ASSET));

    Accounting accounting = new Accounting(address(this));

    function setUp() public {
        accounting.createAccount(POOL_A, CASH_ACCOUNT, true);
        accounting.createAccount(POOL_A, BOND1_INVESTMENT_ACCOUNT, true);
        accounting.createAccount(POOL_A, FEES_EXPENSE_ACCOUNT, true);
        accounting.createAccount(POOL_A, FEES_PAYABLE_ACCOUNT, false);
        accounting.createAccount(POOL_A, EQUITY_ACCOUNT, false);
        accounting.createAccount(POOL_A, GAIN_ACCOUNT, false);
    }

    function testUpdateEntries() public {
        accounting.unlock(POOL_A);
        accounting.updateEntry(EQUITY_ACCOUNT, CASH_ACCOUNT, 500);
        accounting.updateEntry(FEES_PAYABLE_ACCOUNT, EQUITY_ACCOUNT, 100);
        accounting.updateEntry(CASH_ACCOUNT, FEES_PAYABLE_ACCOUNT, 50);
        accounting.lock();

        assertEq(accounting.getAccountValue(POOL_A, CASH_ACCOUNT), 450);
        assertEq(accounting.getAccountValue(POOL_A, EQUITY_ACCOUNT), 400);
        assertEq(accounting.getAccountValue(POOL_A, FEES_PAYABLE_ACCOUNT), 50);
    }

    function testDebitsAndCredits() public {
        accounting.unlock(POOL_A);
        accounting.addDebit(CASH_ACCOUNT, 500);
        accounting.addCredit(EQUITY_ACCOUNT, 500);
        accounting.addDebit(BOND1_INVESTMENT_ACCOUNT, 245);
        accounting.addDebit(FEES_EXPENSE_ACCOUNT, 5);
        accounting.addCredit(CASH_ACCOUNT, 250);
        accounting.lock();

        assertEq(accounting.getAccountValue(POOL_A, CASH_ACCOUNT), 250);
        assertEq(accounting.getAccountValue(POOL_A, EQUITY_ACCOUNT), 500);
        assertEq(accounting.getAccountValue(POOL_A, BOND1_INVESTMENT_ACCOUNT), 245);
        assertEq(accounting.getAccountValue(POOL_A, FEES_EXPENSE_ACCOUNT), 5);
    }

    function testEntriesAndDebitsAndCredits() public {
        accounting.unlock(POOL_A);

        vm.expectEmit(true, false, true, true);
        emit IAccounting.Debit(POOL_A, 0, CASH_ACCOUNT, 500);
        vm.expectEmit(true, false, true, true);
        emit IAccounting.Credit(POOL_A, 0, EQUITY_ACCOUNT, 500);
        accounting.updateEntry(EQUITY_ACCOUNT, CASH_ACCOUNT, 500);

        vm.expectEmit(true, false, true, true);
        emit IAccounting.Debit(POOL_A, 0, BOND1_INVESTMENT_ACCOUNT, 250);
        accounting.addDebit(BOND1_INVESTMENT_ACCOUNT, 250);

        vm.expectEmit(true, false, true, true);
        emit IAccounting.Credit(POOL_A, 0, CASH_ACCOUNT, 250);
        accounting.addCredit(CASH_ACCOUNT, 250);
        accounting.lock();

        assertEq(accounting.getAccountValue(POOL_A, CASH_ACCOUNT), 250);
        assertEq(accounting.getAccountValue(POOL_A, EQUITY_ACCOUNT), 500);
        assertEq(accounting.getAccountValue(POOL_A, BOND1_INVESTMENT_ACCOUNT), 250);
    }

    function testPoolIsolation() public {
        accounting.createAccount(POOL_B, CASH_ACCOUNT, true);
        accounting.createAccount(POOL_B, EQUITY_ACCOUNT, false);

        accounting.unlock(POOL_A);
        accounting.updateEntry(EQUITY_ACCOUNT, CASH_ACCOUNT, 500);
        accounting.lock();

        accounting.unlock(POOL_B);
        accounting.updateEntry(EQUITY_ACCOUNT, CASH_ACCOUNT, 120);
        accounting.lock();

        assertEq(accounting.getAccountValue(POOL_A, CASH_ACCOUNT), 500);
        assertEq(accounting.getAccountValue(POOL_A, EQUITY_ACCOUNT), 500);
        assertEq(accounting.getAccountValue(POOL_B, CASH_ACCOUNT), 120);
        assertEq(accounting.getAccountValue(POOL_B, EQUITY_ACCOUNT), 120);
    }

    function testUnequalDebitsAndCredits(uint128 v) public {
        vm.assume(v != 5);
        vm.assume(v < type(uint128).max - 250);

        accounting.unlock(POOL_A);
        accounting.updateEntry(EQUITY_ACCOUNT, CASH_ACCOUNT, 500);
        accounting.addDebit(BOND1_INVESTMENT_ACCOUNT, 245);
        accounting.addDebit(FEES_EXPENSE_ACCOUNT, v);
        accounting.addCredit(CASH_ACCOUNT, 250);

        vm.expectRevert(IAccounting.Unbalanced.selector);
        accounting.lock();
    }

    function testDoubleUnlock() public {
        accounting.unlock(POOL_A);

        vm.expectRevert(IAccounting.AccountingAlreadyUnlocked.selector);
        accounting.unlock(POOL_B);
    }

    function testUpdateEntryWithoutUnlocking() public {
        vm.expectRevert(IAccounting.AccountingLocked.selector);
        accounting.updateEntry(EQUITY_ACCOUNT, CASH_ACCOUNT, 1);

        vm.expectRevert(IAccounting.AccountingLocked.selector);
        accounting.addDebit(CASH_ACCOUNT, 1);

        vm.expectRevert(IAccounting.AccountingLocked.selector);
        accounting.addCredit(EQUITY_ACCOUNT, 1);
    }

    function testNotWard() public {
        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.unlock(POOL_A);

        accounting.unlock(POOL_A);

        vm.startPrank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.updateEntry(EQUITY_ACCOUNT, CASH_ACCOUNT, 500);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.addDebit(CASH_ACCOUNT, 500);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.addCredit(EQUITY_ACCOUNT, 500);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.lock();

        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.createAccount(POOL_A, NON_INITIALIZED_ACCOUNT, true);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.updateAccountMetadata(POOL_A, CASH_ACCOUNT, "cash");
    }

    function testUpdatingNonExistentAccount() public {
        accounting.unlock(POOL_A);
        vm.expectRevert(IAccounting.AccountDoesNotExists.selector);
        accounting.addDebit(NON_INITIALIZED_ACCOUNT, 500);
    }

    function testUpdateMetadata() public {
        accounting.updateAccountMetadata(POOL_A, CASH_ACCOUNT, "cash");
        accounting.updateAccountMetadata(POOL_A, EQUITY_ACCOUNT, "equity");

        (,,,, bytes memory metadata1) = accounting.accounts(POOL_A, CASH_ACCOUNT);
        (,,,, bytes memory metadata2) = accounting.accounts(POOL_A, EQUITY_ACCOUNT);
        (,,,, bytes memory metadata3) = accounting.accounts(POOL_B, EQUITY_ACCOUNT);
        assertEq(metadata1, "cash");
        assertEq(metadata2, "equity");
        assertEq(metadata3, "");
    }

    function testCreatingExistingAccount() public {
        vm.expectRevert(IAccounting.AccountExists.selector);
        accounting.createAccount(POOL_A, CASH_ACCOUNT, true);
    }
}
