// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccounting} from "src/interfaces/IAccounting.sol";
import {AccountId} from "src/types/AccountId.sol";
import {PoolId} from "src/types/PoolId.sol";
import {PoolLocker} from "src/PoolLocker.sol";
import {Auth} from "src/Auth.sol";

contract Accounting is Auth, IAccounting {
    mapping(PoolId => mapping(AccountId => Account)) public accounts;

    uint128 private /*TODO: transient*/ _debited;
    uint128 private /*TODO: transient*/ _credited;
    uint256 private /*TODO: transient*/ _transactionId;
    PoolId private /*TODO: transient*/ _currentPoolId;

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IAccounting
    function updateEntry(AccountId creditAccount, AccountId debitAccount, uint128 value) external auth {
        require(PoolId.unwrap(_currentPoolId) != 0, PoolLocked());
        _debit(debitAccount, value);
        _credit(creditAccount, value);
        emit Entry(_currentPoolId, _transactionId, creditAccount, debitAccount, value);
    }

    /// @inheritdoc IAccounting
    function unlock(PoolId poolId) external auth {
        require(PoolId.unwrap(_currentPoolId) == 0, PoolAlreadyUnlocked());
        _debited = 0;
        _credited = 0;
        /// @dev Include the previous transactionId in case there's multiple transactions in one block
        _transactionId = uint256(keccak256(abi.encodePacked(poolId, block.timestamp, _transactionId)));
        _currentPoolId = poolId;
    }

    /// @inheritdoc IAccounting
    function lock() external auth {
        require(_debited == _credited, Unbalanced());
        _currentPoolId = PoolId.wrap(0);
    }

    /// @inheritdoc IAccounting
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal, bytes calldata metadata)
        external
        auth
    {
        require(accounts[poolId][account].lastUpdated == 0, AccountExists());
        accounts[poolId][account] = Account(0, metadata, isDebitNormal, uint64(block.timestamp));
    }

    /// @dev Debits an account. Increase the balance of debit-normal accounts, decrease for credit-normal ones.
    function _debit(AccountId account, uint128 value) internal {
        Account storage acc = accounts[_currentPoolId][account];

        if (acc.isDebitNormal) {
            acc.balance += int256(uint256(value));
        } else {
            acc.balance -= int256(uint256(value));
        }
        _debited += value;
        acc.lastUpdated = uint64(block.timestamp);
    }

    /// @dev Credits an account. Decrease the balance of debit-normal accounts, increase for credit-normal ones.
    function _credit(AccountId account, uint128 value) internal {
        Account storage acc = accounts[_currentPoolId][account];

        if (acc.isDebitNormal) {
            acc.balance -= int256(uint256(value));
        } else {
            acc.balance += int256(uint256(value));
        }
        _credited += value;
        acc.lastUpdated = uint64(block.timestamp);
    }

    /// @inheritdoc IAccounting
    function getAccountValue(PoolId poolId, AccountId account) public view returns (int256) {
        Account storage acc = accounts[poolId][account];

        if (acc.isDebitNormal) {
            return acc.balance;
        } else {
            return -acc.balance;
        }
    }
}
