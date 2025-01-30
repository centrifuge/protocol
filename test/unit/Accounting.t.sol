// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Accounting} from "src/Accounting.sol";
import {IAccounting} from "src/interfaces/IAccounting.sol";
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
    AccountId immutable FEES_EXPENSE_ACCOUNT = accountId(401, uint8(AccountType.ASSET));
    AccountId immutable FEES_PAYABLE_ACCOUNT = accountId(201, uint8(AccountType.LOSS));
    AccountId immutable EQUITY_ACCOUNT = accountId(301, uint8(AccountType.EQUITY));
    AccountId immutable GAIN_ACCOUNT = accountId(302, uint8(AccountType.GAIN));

    Accounting accounting = new Accounting(address(this));

    function setUp() public {
        accounting.createAccount(POOL_A, CASH_ACCOUNT, true, "");
        accounting.createAccount(POOL_A, FEES_EXPENSE_ACCOUNT, true, "");
        accounting.createAccount(POOL_A, FEES_PAYABLE_ACCOUNT, false, "");
        accounting.createAccount(POOL_A, EQUITY_ACCOUNT, false, "");
        accounting.createAccount(POOL_A, GAIN_ACCOUNT, false, "");
    }

    function testUpdateEntry() public {
        accounting.unlock(POOL_A);
        accounting.updateEntry(EQUITY_ACCOUNT, CASH_ACCOUNT, 500);
        accounting.updateEntry(FEES_PAYABLE_ACCOUNT, EQUITY_ACCOUNT, 100);
        accounting.updateEntry(CASH_ACCOUNT, FEES_PAYABLE_ACCOUNT, 50);
        accounting.lock();

        assertEq(accounting.getAccountValue(POOL_A, CASH_ACCOUNT), 450);
        assertEq(accounting.getAccountValue(POOL_A, EQUITY_ACCOUNT), -400);
        assertEq(accounting.getAccountValue(POOL_A, FEES_PAYABLE_ACCOUNT), -50);
    }

    function testDoubleUnlock() public {
        accounting.unlock(POOL_A);

        vm.expectRevert(IAccounting.PoolAlreadyUnlocked.selector);
        accounting.unlock(POOL_B);
    }

    function testUpdateEntryWithoutUnlocking() public {
        vm.expectRevert(IAccounting.PoolLocked.selector);
        accounting.updateEntry(EQUITY_ACCOUNT, CASH_ACCOUNT, 500);
    }
}
