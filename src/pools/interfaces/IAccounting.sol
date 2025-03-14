// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccountId} from "src/pools/types/AccountId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";

interface IAccounting {
    /// @notice Emitted when a an entry is done
    event Credit(PoolId indexed poolId, bytes32 indexed transactionId, AccountId indexed account, uint128 value);
    event Debit(PoolId indexed poolId, bytes32 indexed transactionId, AccountId indexed account, uint128 value);
    
    event AccountCreated(PoolId indexed poolId, AccountId indexed account, bool isDebitNormal);
    event AccountMetadataSet(PoolId indexed poolId, AccountId indexed account, bytes metadata);

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

    /// @notice Represents an account
    struct Account {
        uint128 totalDebit;
        uint128 totalCredit;
        bool isDebitNormal;
        uint64 lastUpdated;
        bytes metadata;
    }

    /// @notice Debits an account. Increase the value of debit-normal accounts, decrease for credit-normal ones.
    /// @param account The account to debit
    /// @param value Amount being debited
    function addDebit(AccountId account, uint128 value) external;

    /// @notice Credits an account. Decrease the value of debit-normal accounts, increase for credit-normal ones.
    /// @param account The account to credit
    /// @param value Amount being credited
    function addCredit(AccountId account, uint128 value) external;

    /// @notice Sets the pool ID and transaction ID for the coming transaction.
    /// @param poolId The pool to unlock
    /// @param transactionId The id to use for this set of debits/credits
    function unlock(PoolId poolId, bytes32 transactionId) external;

    /// @notice Closes the transaction and checks if the entries are balanced.
    function lock() external;

    /// @notice Creates an account.
    /// @param poolId The pool the account belongs to
    /// @param account The account to create
    /// @param isDebitNormal Whether the account is debit-normal or credit-normal
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal) external;

    /// @notice Sets metadata associated to an existent account.
    /// @param poolId The pool the account belongs to
    /// @param account The account to set metadata for
    /// @param metadata The metadata to set
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external;

    /// @notice Returns the value of an account
    /// @param poolId The pool the account belongs to
    /// @param account The account to get the value of
    /// @return The value of the account. Will be a negative value for positive balances of credt-normal accounts
    function accountValue(PoolId poolId, AccountId account) external returns (int128);
}
