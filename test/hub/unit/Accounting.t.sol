// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {Accounting} from "src/hub/Accounting.sol";
import {IAccounting, JournalEntry} from "src/hub/interfaces/IAccounting.sol";

enum AccountType {
    Asset,
    Equity,
    Loss,
    Gain
}

PoolId constant POOL_A = PoolId.wrap(33);
PoolId constant POOL_B = PoolId.wrap(44);

contract AccountingTest is Test {
    AccountId immutable CASH_ACCOUNT = AccountId.wrap(1);
    AccountId immutable BOND1_INVESTMENT_ACCOUNT = AccountId.wrap(101);
    AccountId immutable FEES_EXPENSE_ACCOUNT = AccountId.wrap(401);
    AccountId immutable FEES_PAYABLE_ACCOUNT = AccountId.wrap(201);
    AccountId immutable EQUITY_ACCOUNT = AccountId.wrap(301);
    AccountId immutable GAIN_ACCOUNT = AccountId.wrap(302);
    AccountId immutable NON_INITIALIZED_ACCOUNT = AccountId.wrap(999);
    JournalEntry[] EMPTY_JOURNAL_ENTRY;

    Accounting accounting = new Accounting(address(this));

    function setUp() public {
        accounting.createAccount(POOL_A, CASH_ACCOUNT, true);
        accounting.createAccount(POOL_A, BOND1_INVESTMENT_ACCOUNT, true);
        accounting.createAccount(POOL_A, FEES_EXPENSE_ACCOUNT, true);
        accounting.createAccount(POOL_A, FEES_PAYABLE_ACCOUNT, false);
        accounting.createAccount(POOL_A, EQUITY_ACCOUNT, false);
        accounting.createAccount(POOL_A, GAIN_ACCOUNT, false);
    }

    function beforeTestSetup(bytes4 testSelector) public pure returns (bytes[] memory beforeTestCalldata) {
        if (testSelector == this.testJournalId.selector) {
            beforeTestCalldata = new bytes[](1);
            beforeTestCalldata[0] = abi.encode(this.setupJournalId.selector);
        }
    }

    function _assertEqValue(PoolId poolId, AccountId accountId, bool expectedIsPositive, uint128 expectedValue)
        internal
        view
    {
        (bool isPositive, uint128 value) = accounting.accountValue(poolId, accountId);
        assertEq(isPositive, expectedIsPositive, "Mismatch: Accounting.accountValue - isPositive");
        assertEq(value, expectedValue, "Mismatch: Accounting.accountValue - value");
    }

    function testAccount() public {
        vm.expectEmit();
        emit IAccounting.CreateAccount(POOL_B, CASH_ACCOUNT, true);
        accounting.createAccount(POOL_B, CASH_ACCOUNT, true);

        vm.expectEmit();
        emit IAccounting.SetAccountMetadata(POOL_B, CASH_ACCOUNT, "cash");
        accounting.setAccountMetadata(POOL_B, CASH_ACCOUNT, "cash");

        (,,,, bytes memory metadata) = accounting.accounts(POOL_B, CASH_ACCOUNT);
        assertEq(metadata, "cash");
    }

    function testDebitsAndCredits() public {
        accounting.unlock(POOL_A);

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

        _assertEqValue(POOL_A, CASH_ACCOUNT, true, 250);
        _assertEqValue(POOL_A, EQUITY_ACCOUNT, true, 500);
        _assertEqValue(POOL_A, BOND1_INVESTMENT_ACCOUNT, true, 245);
        _assertEqValue(POOL_A, FEES_EXPENSE_ACCOUNT, true, 5);
    }

    function testPoolIsolation() public {
        accounting.createAccount(POOL_B, CASH_ACCOUNT, true);
        accounting.createAccount(POOL_B, EQUITY_ACCOUNT, false);

        accounting.unlock(POOL_A);
        accounting.addDebit(CASH_ACCOUNT, 500);
        accounting.addCredit(EQUITY_ACCOUNT, 500);
        accounting.lock();

        accounting.unlock(POOL_B);
        accounting.addDebit(CASH_ACCOUNT, 120);
        accounting.addCredit(EQUITY_ACCOUNT, 120);
        accounting.lock();

        _assertEqValue(POOL_A, CASH_ACCOUNT, true, 500);
        _assertEqValue(POOL_A, EQUITY_ACCOUNT, true, 500);
        _assertEqValue(POOL_B, CASH_ACCOUNT, true, 120);
        _assertEqValue(POOL_B, EQUITY_ACCOUNT, true, 120);
    }

    function testUnequalDebitsAndCredits(uint128 v) public {
        vm.assume(v != 5);
        vm.assume(v < type(uint128).max - 250);

        accounting.unlock(POOL_A);
        accounting.addDebit(CASH_ACCOUNT, 500);
        accounting.addCredit(EQUITY_ACCOUNT, 500);
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
        accounting.addDebit(CASH_ACCOUNT, 500);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.addCredit(EQUITY_ACCOUNT, 500);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.addJournal(EMPTY_JOURNAL_ENTRY, EMPTY_JOURNAL_ENTRY);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.lock();

        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.createAccount(POOL_A, NON_INITIALIZED_ACCOUNT, true);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        accounting.setAccountMetadata(POOL_A, CASH_ACCOUNT, "cash");
    }

    function testErrWhenNonExistentAccount() public {
        accounting.unlock(POOL_A);
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

    function setupJournalId() public {
        // Unlock and lock POOL_A in a separate transaction,
        // so it has a different pool counter and its transient storage is cleared.
        accounting.unlock(POOL_A);
        accounting.lock();
    }

    function testJournalId() public {
        vm.expectEmit();
        emit IAccounting.StartJournalId(POOL_A, (uint256(POOL_A.raw()) << 128) | 2);
        accounting.unlock(POOL_A);

        vm.expectEmit();
        emit IAccounting.EndJournalId(POOL_A, (uint256(POOL_A.raw()) << 128) | 2);
        accounting.lock();

        vm.expectEmit();
        emit IAccounting.StartJournalId(POOL_A, (uint256(POOL_A.raw()) << 128) | 2);
        accounting.unlock(POOL_A);

        vm.expectEmit();
        emit IAccounting.EndJournalId(POOL_A, (uint256(POOL_A.raw()) << 128) | 2);
        accounting.lock();

        vm.expectEmit();
        emit IAccounting.StartJournalId(POOL_B, (uint256(POOL_B.raw()) << 128) | 1);
        accounting.unlock(POOL_B);

        vm.expectEmit();
        emit IAccounting.EndJournalId(POOL_B, (uint256(POOL_B.raw()) << 128) | 1);
        accounting.lock();
    }
}
