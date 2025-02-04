// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccounting} from "src/interfaces/IAccounting.sol";
import {AccountId} from "src/types/AccountId.sol";
import {PoolId} from "src/types/PoolId.sol";
import {PoolLocker} from "src/PoolLocker.sol";
import {Auth} from "src/Auth.sol";

contract Accounting is Auth, IAccounting {
    mapping(PoolId => mapping(AccountId => Account)) public accounts;
    mapping(PoolId => uint128) private _transactionCounter;

    uint128 public /*TODO: transient*/ debited;
    uint128 public /*TODO: transient*/ credited;
    uint256 private /*TODO: transient*/ _transactionId;
    PoolId private /*TODO: transient*/ _currentPoolId;

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
    function unlock(PoolId poolId) external auth {
        require(PoolId.unwrap(_currentPoolId) == 0, AccountingAlreadyUnlocked());
        debited = 0;
        credited = 0;
        _transactionCounter[poolId]++;
        _transactionId = uint256(keccak256(abi.encodePacked(poolId, block.timestamp, _transactionCounter[poolId])));
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

    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external auth {
        Account storage acc = accounts[poolId][account];
        acc.metadata = metadata;
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
