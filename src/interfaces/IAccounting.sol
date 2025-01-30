// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccountId} from "src/types/AccountId.sol";
import {PoolId} from "src/types/PoolId.sol";

interface IAccounting {
    /// @notice Emitted when a an entry is done
    event Entry(
        PoolId indexed poolId,
        uint256 indexed transactionId,
        AccountId creditAccount,
        AccountId debitAccount,
        uint128 value
    );

    /// @notice Dispatched when the pool is already unlocked.
    error PoolAlreadyUnlocked();

    /// @notice Dispatched when the pool is not unlocked to interact with.
    error PoolLocked();

    /// @notice Dispatched when the debit and credit side do not match at the end of a transaction.
    error Unbalanced();

    /// @notice Dispatched when trying to create an account that already exists.
    error AccountExists();

    /// @notice
    struct Account {
        int256 balance;
        bytes metadata;
        bool isDebitNormal;
        uint64 lastUpdated;
    }

    /// @notice Logs an entry where one account is debited and another is credited.
    function updateEntry(AccountId creditAccount, AccountId debitAccount, uint128 value) external;

    /// @notice Sets the pool for the coming transaction.
    function unlock(PoolId poolId) external;

    /// @notice Closes the transaction and checks if the entries are balanced.
    function lock() external;

    /// @notice Creates an account.
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal, bytes calldata metadata) external;

    /// @notice Returns the value of an account, returns a negative value for positive balances of credt-normal
    /// accounts.
    function getAccountValue(PoolId poolId, AccountId account) external returns (int256);
}
