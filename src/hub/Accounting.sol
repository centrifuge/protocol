// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {AccountId} from "src/common/types/AccountId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {IAccounting, JournalEntry} from "src/hub/interfaces/IAccounting.sol";
import {TransientStorageLib} from "src/misc/libraries/TransientStorageLib.sol";

/// @notice In a transaction there can be multiple journal entries for different pools,
/// which can be interleaved. We want entries for the same pool to share the same journal ID.
/// So we're keeping a journal ID per pool in transient storage.
library TransientJournal {
    function journalId(PoolId poolId) internal view returns (uint256) {
        return TransientStorageLib.tloadUint256(keccak256(abi.encode("journalId", poolId)));
    }

    function setJournalId(PoolId poolId, uint256 value) internal {
        TransientStorageLib.tstore(keccak256(abi.encode("journalId", poolId)), value);
    }
}

/// @title  Accounting
/// @notice Double-entry bookkeeping system.
/// @dev    To add entries, a specific pool needs to be unlocked.
///         When locking, the debited and credited amounts need to match.
contract Accounting is Auth, IAccounting {
    mapping(PoolId => mapping(AccountId => Account)) public accounts;

    uint128 public transient debited;
    uint128 public transient credited;
    PoolId internal transient _currentPoolId;
    mapping(PoolId => uint64) internal _poolJournalIdCounter;

    constructor(address deployer) Auth(deployer) {}

    //----------------------------------------------------------------------------------------------
    // Lock/unlock
    //----------------------------------------------------------------------------------------------

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

    //----------------------------------------------------------------------------------------------
    // Account creation & metadata
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAccounting
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal) external auth {
        require(accounts[poolId][account].lastUpdated == 0, AccountExists());
        accounts[poolId][account] = Account(0, 0, isDebitNormal, uint64(block.timestamp), "");
        emit CreateAccount(poolId, account, isDebitNormal);
    }

    /// @inheritdoc IAccounting
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external auth {
        require(accounts[poolId][account].lastUpdated != 0, AccountDoesNotExist());
        accounts[poolId][account].metadata = metadata;
        emit SetAccountMetadata(poolId, account, metadata);
    }
    
    //----------------------------------------------------------------------------------------------
    // Account updates
    //----------------------------------------------------------------------------------------------

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
    function addJournal(JournalEntry[] memory debits, JournalEntry[] memory credits) external auth {
        for (uint256 i; i < debits.length; i++) {
            addDebit(debits[i].accountId, debits[i].value);
        }

        for (uint256 i; i < credits.length; i++) {
            addCredit(credits[i].accountId, credits[i].value);
        }
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAccounting
    function accountValue(PoolId poolId, AccountId account) external view returns (bool /* isPositive */, uint128) {
        Account storage acc = accounts[poolId][account];
        require(acc.lastUpdated != 0, AccountDoesNotExist());

        if (acc.isDebitNormal) {
            // For debit-normal accounts: Value = Total Debit - Total Credit
            if (acc.totalDebit >= acc.totalCredit) {
                return (true, acc.totalDebit - acc.totalCredit);
            } else {
                return (false, acc.totalCredit - acc.totalDebit);
            }
        } else {
            // For credit-normal accounts: Value = Total Credit - Total Debit
            if (acc.totalCredit >= acc.totalDebit) {
                return (true, acc.totalCredit - acc.totalDebit);
            } else {
                return (false, acc.totalDebit - acc.totalCredit);
            }
        }
    }

    /// @inheritdoc IAccounting
    function exists(PoolId poolId, AccountId account) external view returns (bool) {
        return accounts[poolId][account].lastUpdated != 0;
    }

    function _generateJournalId(PoolId poolId) internal returns (uint256) {
        return uint256((uint256(poolId.raw()) << 128) | ++_poolJournalIdCounter[poolId]);
    }
}
