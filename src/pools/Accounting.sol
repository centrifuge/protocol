// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {AccountId} from "src/pools/types/AccountId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {IAccounting} from "src/pools/interfaces/IAccounting.sol";
import {TransientStorage} from "src/misc/libraries/TransientStorage.sol";

/// @notice In a transaction there can be multiple journal entries for different pools,
/// which can be interleaved. We want entries for the same pool to share the same journal ID.
/// So we're keeping a journal ID per pool in transient storage.
library TransientJournal {
    function journalId(PoolId poolId) internal view returns (uint256) {
        return TransientStorage.tloadUint256(keccak256(abi.encode("journalId", poolId)));
    }

    function setJournalId(PoolId poolId, uint256 value) internal {
        TransientStorage.tstore(keccak256(abi.encode("journalId", poolId)), value);
    }
}

contract Accounting is Auth, IAccounting {
    mapping(PoolId => mapping(AccountId => Account)) public accounts;

    uint128 public transient debited;
    uint128 public transient credited;
    PoolId internal transient _currentPoolId;
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
    function unlock(PoolId poolId) external auth {
        require(PoolId.unwrap(_currentPoolId) == 0, AccountingAlreadyUnlocked());
        debited = 0;
        credited = 0;
        _currentPoolId = poolId;
        
        if (TransientJournal.journalId(poolId) == 0) {
            TransientJournal.setJournalId(poolId, _generateJournalId(poolId));
        }
        emit StartJournalId(poolId, TransientJournal.journalId(poolId));
    }

    /// @inheritdoc IAccounting
    function lock() external auth {
        require(debited == credited, Unbalanced());

        emit EndJournalId(_currentPoolId, TransientJournal.journalId(_currentPoolId));
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

    function _generateJournalId(PoolId poolId) internal returns (uint256) {
        return uint256((uint128(poolId.raw()) << 64) | ++_poolJournalIdCounter[poolId]);
    }
}
