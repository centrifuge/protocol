// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {AccountId} from "src/common/types/AccountId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {IAccounting} from "src/pools/interfaces/IAccounting.sol";

contract Accounting is Auth, IAccounting {
    mapping(PoolId => mapping(AccountId => Account)) public accounts;

    uint128 public transient debited;
    uint128 public transient credited;
    PoolId internal transient _currentPoolId;
    /// @inheritdoc IAccounting
    uint256 public transient journalId;

    mapping(PoolId => uint64) internal _poolJournalIdCounter;

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IAccounting
    function addDebit(AccountId account, uint128 value) public auth {
        require(!_currentPoolId.isNull(), AccountingLocked());

        Account storage acc = accounts[_currentPoolId][account];
        require(acc.lastUpdated != 0, AccountDoesNotExist());

        acc.totalDebit += value;
        debited += value;
        acc.lastUpdated = uint64(block.timestamp);
        emit Debit(_currentPoolId, account, value);
    }

    /// @inheritdoc IAccounting
    function addCredit(AccountId account, uint128 value) public auth {
        require(!_currentPoolId.isNull(), AccountingLocked());

        Account storage acc = accounts[_currentPoolId][account];
        require(acc.lastUpdated != 0, AccountDoesNotExist());

        acc.totalCredit += value;
        credited += value;
        acc.lastUpdated = uint64(block.timestamp);
        emit Credit(_currentPoolId, account, value);
    }

    /// @inheritdoc IAccounting
    function unlock(PoolId poolId, uint256 journalId_) external auth {
        require(PoolId.unwrap(_currentPoolId) == 0, AccountingAlreadyUnlocked());
        debited = 0;
        credited = 0;
        journalId = journalId_;
        _currentPoolId = poolId;
        emit StartJournalId(poolId, journalId_);
    }

    /// @inheritdoc IAccounting
    function lock() external auth {
        require(debited == credited, Unbalanced());
        emit EndJournalId(_currentPoolId, journalId);
        _currentPoolId = PoolId.wrap(0);
    }

    /// @inheritdoc IAccounting
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal) external auth {
        require(accounts[poolId][account].lastUpdated == 0, AccountExists());
        accounts[poolId][account] = Account(0, 0, isDebitNormal, uint64(block.timestamp), "");
    }

    /// @inheritdoc IAccounting
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external auth {
        require(accounts[poolId][account].lastUpdated != 0, AccountDoesNotExist());
        accounts[poolId][account].metadata = metadata;
    }

    /// @inheritdoc IAccounting
    function accountValue(PoolId poolId, AccountId account) public view returns (int128) {
        Account storage acc = accounts[poolId][account];
        require(acc.lastUpdated != 0, AccountDoesNotExist());

        if (acc.isDebitNormal) {
            // For debit-normal accounts: Value = Total Debit - Total Credit
            return int128(acc.totalDebit) - int128(acc.totalCredit);
        } else {
            // For credit-normal accounts: Value = Total Credit - Total Debit
            return int128(acc.totalCredit) - int128(acc.totalDebit);
        }
    }

    /// @inheritdoc IAccounting
    function generateJournalId(PoolId poolId) external auth returns (uint256) {
        journalId = uint256((uint128(poolId.raw()) << 64) | ++_poolJournalIdCounter[poolId]);
        return journalId;
    }
}
