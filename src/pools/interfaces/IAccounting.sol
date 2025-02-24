// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccountId} from "src/pools/types/AccountId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";

interface IAccounting {
    /// @notice Emitted when a an entry is done
    event Credit(PoolId indexed poolId, bytes32 indexed transactionId, AccountId indexed account, uint128 value);
    event Debit(PoolId indexed poolId, bytes32 indexed transactionId, AccountId indexed account, uint128 value);

    /// @notice Dispatched when the pool is already unlocked.
    error AccountingAlreadyUnlocked();

    /// @notice Dispatched when the pool is not unlocked to interact with.
    error AccountingLocked();

    /// @notice Dispatched when the debit and credit side do not match at the end of a transaction.
    error Unbalanced();

    /// @notice Dispatched when trying to create an account that already exists.
    error AccountExists();

    /// @notice Dispatched when trying debit or credit an account that doesn't exists.
    error AccountDoesNotExist();

    /// @notice
    struct Account {
        uint128 totalDebit;
        uint128 totalCredit;
        bool isDebitNormal;
        uint64 lastUpdated;
        bytes metadata;
    }

    /// @notice Debits an account. Increase the value of debit-normal accounts, decrease for credit-normal ones.
    function addDebit(AccountId account, uint128 value) external;

    /// @notice Credits an account. Decrease the value of debit-normal accounts, increase for credit-normal ones.
    function addCredit(AccountId account, uint128 value) external;

    /// @notice Sets the pool ID and transaction ID for the coming transaction.
    function unlock(PoolId poolId, bytes32 transactionId) external;

    /// @notice Closes the transaction and checks if the entries are balanced.
    function lock() external;

    /// @notice Creates an account.
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal) external;

    /// @notice Sets metadata associated to an existent account.
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external;

    /// @notice Returns the value of an account, returns a negative value for positive balances of credt-normal
    /// accounts.
    function accountValue(PoolId poolId, AccountId account) external returns (int128);
}
