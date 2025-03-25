// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AccountId, newAccountId} from "src/common/types/AccountId.sol";
import {IAccounting} from "src/pools/interfaces/IAccounting.sol";
import {Accounting} from "src/pools/Accounting.sol";

enum AccountType {
    ASSET,
    EQUITY,
    LOSS,
    GAIN
}

PoolId constant POOL_A = PoolId.wrap(33);
PoolId constant POOL_B = PoolId.wrap(44);

contract AccountingTest is Test {
    AccountId immutable CASH_ACCOUNT = newAccountId(1, uint8(AccountType.ASSET));
    AccountId immutable BOND1_INVESTMENT_ACCOUNT = newAccountId(101, uint8(AccountType.ASSET));
    AccountId immutable FEES_EXPENSE_ACCOUNT = newAccountId(401, uint8(AccountType.ASSET));
    AccountId immutable FEES_PAYABLE_ACCOUNT = newAccountId(201, uint8(AccountType.LOSS));
    AccountId immutable EQUITY_ACCOUNT = newAccountId(301, uint8(AccountType.EQUITY));
    AccountId immutable GAIN_ACCOUNT = newAccountId(302, uint8(AccountType.GAIN));
    AccountId immutable NON_INITIALIZED_ACCOUNT = newAccountId(999, uint8(AccountType.ASSET));

    Accounting accounting = new Accounting(address(this));

    function setUp() public {
        accounting.createAccount(POOL_A, CASH_ACCOUNT, true);
        accounting.createAccount(POOL_A, BOND1_INVESTMENT_ACCOUNT, true);
        accounting.createAccount(POOL_A, FEES_EXPENSE_ACCOUNT, true);
        accounting.createAccount(POOL_A, FEES_PAYABLE_ACCOUNT, false);
        accounting.createAccount(POOL_A, EQUITY_ACCOUNT, false);
        accounting.createAccount(POOL_A, GAIN_ACCOUNT, false);
    }

    function testDebitsAndCredits() public {
        accounting.unlock(POOL_A, 1);

        vm.expectEmit();
        emit IAccounting.Debit(POOL_A, CASH_ACCOUNT, 500);
        accounting.addDebit(CASH_ACCOUNT, 500);

        vm.expectEmit();
        emit IAccounting.Credit(POOL_A, EQUITY_ACCOUNT, 500);
        accounting.addCredit(EQUITY_ACCOUNT, 500);

        accounting.addDebit(BOND1_INVESTMENT_ACCOUNT, 245);
        accounting.addDebit(FEES_EXPENSE_ACCOUNT, 5);
        accounting.addCredit(CASH_ACCOUNT, 250);
        accounting.lock();

        assertEq(accounting.accountValue(POOL_A, CASH_ACCOUNT), 250);
        assertEq(accounting.accountValue(POOL_A, EQUITY_ACCOUNT), 500);
        assertEq(accounting.accountValue(POOL_A, BOND1_INVESTMENT_ACCOUNT), 245);
        assertEq(accounting.accountValue(POOL_A, FEES_EXPENSE_ACCOUNT), 5);
    }

    function testPoolIsolation() public {
        accounting.createAccount(POOL_B, CASH_ACCOUNT, true);
        accounting.createAccount(POOL_B, EQUITY_ACCOUNT, false);

        accounting.unlock(POOL_A, 1);
        accounting.addDebit(CASH_ACCOUNT, 500);
        accounting.addCredit(EQUITY_ACCOUNT, 500);
        accounting.lock();

        accounting.unlock(POOL_B, 2);
        accounting.addDebit(CASH_ACCOUNT, 120);
        accounting.addCredit(EQUITY_ACCOUNT, 120);
        accounting.lock();

        assertEq(accounting.accountValue(POOL_A, CASH_ACCOUNT), 500);
        assertEq(accounting.accountValue(POOL_A, EQUITY_ACCOUNT), 500);
        assertEq(accounting.accountValue(POOL_B, CASH_ACCOUNT), 120);
        assertEq(accounting.accountValue(POOL_B, EQUITY_ACCOUNT), 120);
    }

    function testUnequalDebitsAndCredits(uint128 v) public {
        vm.assume(v != 5);
        vm.assume(v < type(uint128).max - 250);

        accounting.unlock(POOL_A, 1);
        accounting.addDebit(CASH_ACCOUNT, 500);
        accounting.addCredit(EQUITY_ACCOUNT, 500);
        accounting.addDebit(BOND1_INVESTMENT_ACCOUNT, 245);
        accounting.addDebit(FEES_EXPENSE_ACCOUNT, v);
        accounting.addCredit(CASH_ACCOUNT, 250);

        vm.expectRevert(IAccounting.Unbalanced.selector);
        accounting.lock();
    }

    function testDoubleUnlock() public {
        accounting.unlock(POOL_A, 1);

        vm.expectRevert(IAccounting.AccountingAlreadyUnlocked.selector);
        accounting.unlock(POOL_B, 1);
    }

    function testUpdateEntryWithoutUnlocking() public {
        vm.expectRevert(IAccounting.AccountingLocked.selector);
        accounting.addDebit(CASH_ACCOUNT, 1);

        vm.expectRevert(IAccounting.AccountingLocked.selector);
        accounting.addCredit(EQUITY_ACCOUNT, 1);
    }

    function testNotWard() public {
        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.unlock(POOL_A, 1);

        accounting.unlock(POOL_A, 1);

        vm.startPrank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.addDebit(CASH_ACCOUNT, 500);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.addCredit(EQUITY_ACCOUNT, 500);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.lock();

        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.createAccount(POOL_A, NON_INITIALIZED_ACCOUNT, true);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.setAccountMetadata(POOL_A, CASH_ACCOUNT, "cash");
    }

    function testErrWhenNonExistentAccount() public {
        accounting.unlock(POOL_A, 1);
        vm.expectRevert(IAccounting.AccountDoesNotExist.selector);
        accounting.addDebit(NON_INITIALIZED_ACCOUNT, 500);

        vm.expectRevert(IAccounting.AccountDoesNotExist.selector);
        accounting.addCredit(NON_INITIALIZED_ACCOUNT, 500);

        vm.expectRevert(IAccounting.AccountDoesNotExist.selector);
        accounting.setAccountMetadata(POOL_A, NON_INITIALIZED_ACCOUNT, "");

        vm.expectRevert(IAccounting.AccountDoesNotExist.selector);
        accounting.accountValue(POOL_A, NON_INITIALIZED_ACCOUNT);
    }

    function testUpdateMetadata() public {
        accounting.setAccountMetadata(POOL_A, CASH_ACCOUNT, "cash");
        accounting.setAccountMetadata(POOL_A, EQUITY_ACCOUNT, "equity");

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

    function testJournalId() public {
        vm.prank(makeAddr("randomUser"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.generateJournalId(POOL_A);

        uint256 txId = accounting.generateJournalId(POOL_A);
        uint256 expected = (33 << 64) | 1;
        assertEq(txId, expected);
        assertEq(accounting.journalId(), expected);

        uint256 txId2 = accounting.generateJournalId(POOL_A);
        uint256 expected2 = (33 << 64) | 2;
        assertEq(txId2, expected2);
        assertEq(accounting.journalId(), expected2);

        accounting.generateJournalId(POOL_B);
        assertEq(accounting.journalId(), (44 << 64) | 1);
    }
}
