// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {AccountId} from "src/pools/types/AccountId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {IAccounting} from "src/pools/interfaces/IAccounting.sol";

contract Accounting is Auth, IAccounting {
    mapping(PoolId => mapping(AccountId => Account)) public accounts;

    uint128 public transient debited;
    uint128 public transient credited;
    bytes32 private transient _transactionId;
    PoolId private transient _currentPoolId;

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IAccounting
    function addDebit(AccountId account, uint128 value) public auth {
        require(!_currentPoolId.isNull(), AccountingLocked());

        Account storage acc = accounts[_currentPoolId][account];
        require(acc.lastUpdated != 0, AccountDoesNotExist());

        acc.totalDebit += value;
        debited += value;
        acc.lastUpdated = uint64(block.timestamp);
        emit Debit(_currentPoolId, _transactionId, account, value);
    }

    /// @inheritdoc IAccounting
    function addCredit(AccountId account, uint128 value) public auth {
        require(!_currentPoolId.isNull(), AccountingLocked());

        Account storage acc = accounts[_currentPoolId][account];
        require(acc.lastUpdated != 0, AccountDoesNotExist());

        acc.totalCredit += value;
        credited += value;
        acc.lastUpdated = uint64(block.timestamp);
        emit Credit(_currentPoolId, _transactionId, account, value);
    }

    /// @inheritdoc IAccounting
    function unlock(PoolId poolId, bytes32 transactionId) external auth {
        require(PoolId.unwrap(_currentPoolId) == 0, AccountingAlreadyUnlocked());
        debited = 0;
        credited = 0;
        _transactionId = transactionId;
        _currentPoolId = poolId;
    }

    /// @inheritdoc IAccounting
    function lock() external auth {
        require(debited == credited, Unbalanced());
        _currentPoolId = PoolId.wrap(0);
    }

    /// @inheritdoc IAccounting
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal) external auth {
        require(accounts[poolId][account].lastUpdated == 0, AccountExists());
        accounts[poolId][account] = Account(0, 0, isDebitNormal, uint64(block.timestamp), "");
    }

    /// @inheritdoc IAccounting
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external auth {
        accounts[poolId][account].metadata = metadata;
    }

    /// @inheritdoc IAccounting
    function accountValue(PoolId poolId, AccountId account) public view returns (int128) {
        Account storage acc = accounts[poolId][account];

        if (acc.isDebitNormal) {
            // For debit-normal accounts: Value = Total Debit - Total Credit
            return int128(acc.totalDebit) - int128(acc.totalCredit);
        } else {
            // For credit-normal accounts: Value = Total Credit - Total Debit
            return int128(acc.totalCredit) - int128(acc.totalDebit);
        }
    }
}
