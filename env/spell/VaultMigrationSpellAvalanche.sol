// Network: Avalanche (Chain ID: 43114)
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {VaultMigrationSpellCommon} from "./VaultMigrationSpellCommon.sol";

/**
 * @title VaultMigrationSpellAvalanche
 * @notice Avalanche-specific governance spell to migrate 2 collision vaults to CREATE2 deployment
 * @dev Extends VaultMigrationSpellCommon to resolve cross-chain address collisions:
 *      - VAULT_1 (0x04157...958) collides with deJTRSY ETH JTRSY vault
 *      - VAULT_2 (0xCF4C6...Ccf9) collides with deJTRSY ETH USDC vault
 */
contract VaultMigrationSpellAvalanche is VaultMigrationSpellCommon {
    // deJTRSY Avalanche USDC Vault (COLLISION with deJTRSY ETH JTRSY)
    address public constant VAULT_1 = 0x04157759a9fe406d82a16BdEB20F9BeB9bBEb958;
    
    // deJAAA Avalanche USDC Vault (COLLISION with deJTRSY ETH USDC)
    address public constant VAULT_2 = 0xCF4C60066aAB54b3f750F94c2a06046d5466Ccf9;


    constructor(address asyncVaultFactory, address syncDepositVaultFactory) 
        VaultMigrationSpellCommon(asyncVaultFactory, syncDepositVaultFactory) 
    {}

    function _getVaults() internal pure override returns (address[] memory) {
        address[] memory vaults = new address[](2);
        vaults[0] = VAULT_1;  // deJTRSY Avalanche USDC (collision)
        vaults[1] = VAULT_2;  // deJAAA Avalanche USDC (collision)
        return vaults;
    }
}