// Network: Avalanche (Chain ID: 43114)
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {VaultPermissionSpell} from "./VaultPermissionSpell.sol";

import {PoolId} from "../../src/common/types/PoolId.sol";

/**
 * @title VaultPermissionSpellAvalanche
 * @notice Avalanche-specific governance spell with 4 vaults
 */
contract VaultPermissionSpellAvalanche is VaultPermissionSpell {
    // JAAA (Avalanche) & deJAAA (Ethereum) USD vaults
    address public constant VAULT_1 = 0x1121F4e21eD8B9BC1BB9A2952cDD8639aC897784;
    // deJAAA (Avalanche) & deJTRSY (Ethereum) USD vaults
    address public constant VAULT_2 = 0xCF4C60066aAB54b3f750F94c2a06046d5466Ccf9;
    // deJTRSY (Avalanche & Ethereum) USD vaults
    address public constant VAULT_3 = 0x04157759a9fe406d82a16BdEB20F9BeB9bBEb958;
    // JTRSY (Avalanche & Ethereum) USD vaults
    address public constant VAULT_4 = 0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A;

    // VAULT_1: 0x1121F4e21eD8B9BC1BB9A2952cDD8639aC897784
    PoolId public constant POOL_ID_1 = PoolId.wrap(281474976710663);
    // VAULT_2: 0xCF4C60066aAB54b3f750F94c2a06046d5466Ccf9
    PoolId public constant POOL_ID_2 = PoolId.wrap(281474976710659);
    // VAULT_3: 0x04157759a9fe406d82a16BdEB20F9BeB9bBEb958
    PoolId public constant POOL_ID_3 = PoolId.wrap(281474976710660);
    // VAULT_4: 0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A
    PoolId public constant POOL_ID_4 = PoolId.wrap(281474976710662);

    constructor(address newAsyncRequestManager, address newAsyncVaultFactory, address newSyncDepositVaultFactory)
        VaultPermissionSpell(newAsyncRequestManager, newAsyncVaultFactory, newSyncDepositVaultFactory)
    {}

    function _getVaults() internal pure override returns (address[] memory) {
        address[] memory vaults = new address[](4);
        vaults[0] = VAULT_1;
        vaults[1] = VAULT_2;
        vaults[2] = VAULT_3;
        vaults[3] = VAULT_4;
        return vaults;
    }

    function _getPools() internal pure override returns (PoolId[] memory) {
        PoolId[] memory poolIds = new PoolId[](4);
        poolIds[0] = POOL_ID_1;
        poolIds[1] = POOL_ID_2;
        poolIds[2] = POOL_ID_3;
        poolIds[3] = POOL_ID_4;
        return poolIds;
    }
}