// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {AccountId} from "src/pools/types/AccountId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {IAccounting} from "src/pools/interfaces/IAccounting.sol";
import {TransientStorage} from "src/misc/libraries/TransientStorage.sol";

library TransientJournal {
    function debited(PoolId poolId) internal view returns (uint128) {
        return uint128(TransientStorage.tloadUint256(keccak256(abi.encode("debited", poolId))));
    }

    function credited(PoolId poolId) internal view returns (uint128) {
        return uint128(TransientStorage.tloadUint256(keccak256(abi.encode("credited", poolId))));
    }

    function journalId(PoolId poolId) internal view returns (uint256) {
        return TransientStorage.tloadUint256(keccak256(abi.encode("journalId", poolId)));
    }

    function unlocked(PoolId poolId) internal view returns (bool) {
        return TransientStorage.tloadBool(keccak256(abi.encode("unlocked", poolId)));
    }

    function setDebited(PoolId poolId, uint128 value) internal {
        TransientStorage.tstore(keccak256(abi.encode("debited", poolId)), uint256(value));
    }

    function setCredited(PoolId poolId, uint128 value) internal {
        TransientStorage.tstore(keccak256(abi.encode("credited", poolId)), uint256(value));
    }

    function setJournalId(PoolId poolId, uint256 value) internal {
        TransientStorage.tstore(keccak256(abi.encode("journalId", poolId)), value);
    }

    function setUnlocked(PoolId poolId, bool value) internal {
        TransientStorage.tstore(keccak256(abi.encode("unlocked", poolId)), value);
    }
}

contract Accounting is Auth, IAccounting {
    using TransientJournal for PoolId;

    struct JournalEntry {
        uint128 debited;
        uint128 credited;
        uint256 journalId;
        bool unlocked;
    }

    mapping(PoolId => uint64) internal _poolJournalIdCounter;
    mapping(PoolId => mapping(AccountId => Account)) public accounts;

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IAccounting
    function addDebit(PoolId poolId, AccountId account, uint128 value) public auth {
        require(poolId.journalId() != 0, AccountingLocked());

        Account storage acc = accounts[poolId][account];
        require(acc.lastUpdated != 0, AccountDoesNotExist());

        acc.totalDebit += value;
        poolId.setDebited(poolId.debited() + value);
        acc.lastUpdated = uint64(block.timestamp);
        emit Debit(poolId, account, value);
    }

    /// @inheritdoc IAccounting
    function addCredit(PoolId poolId, AccountId account, uint128 value) public auth {
        require(poolId.journalId() != 0, AccountingLocked());

        Account storage acc = accounts[poolId][account];
        require(acc.lastUpdated != 0, AccountDoesNotExist());

        acc.totalCredit += value;
        poolId.setCredited(poolId.credited() + value);
        acc.lastUpdated = uint64(block.timestamp);
        emit Credit(poolId, account, value);
    }

    /// @inheritdoc IAccounting
    function unlock(PoolId poolId) external auth {
        require(!poolId.unlocked(), AccountingAlreadyUnlocked());
        poolId.setDebited(0);
        poolId.setCredited(0);
        poolId.setUnlocked(true);

        if (poolId.journalId() == 0) {
            poolId.setJournalId(_generateJournalId(poolId));
        }
        emit StartJournalId(poolId, poolId.journalId());
    }

    /// @inheritdoc IAccounting
    function lock(PoolId poolId) external auth {
        require(poolId.debited() == poolId.credited(), Unbalanced());
        emit EndJournalId(poolId, poolId.journalId());
        poolId.setUnlocked(false);
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
