// Network: Ethereum (Chain ID: 1)
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Create2VaultFactorySpellCommon} from "./Create2VaultFactorySpellCommon.sol";

/**
 * @title Create2VaultFactorySpellEthereum
 * @notice Ethereum-specific governance spell to migrate 3 vaults to CREATE2 deployment
 * @dev Extends Create2VaultFactorySpellCommon to handle Ethereum collision resolution vaults
 */
contract Create2VaultFactorySpellEthereum is Create2VaultFactorySpellCommon {
    // deJAAA ETH USDC Vault
    address public constant VAULT_1 = 0x1121F4e21eD8B9BC1BB9A2952cDD8639aC897784;
    // deJTRSY ETH USDC Vault
    address public constant VAULT_2 = 0xCF4C60066aAB54b3f750F94c2a06046d5466Ccf9;
    // deJTRSY ETH JTRSY Vault
    address public constant VAULT_3 = 0x04157759a9fe406d82a16BdEB20F9BeB9bBEb958;
    // deJAAA ETH JAAA Vault
    address public constant VAULT_4 = 0x2D38c58Cc7d4DdD6B4DaF7b3539902a7667F4519;

    constructor(address asyncVaultFactory, address syncDepositVaultFactory)
        Create2VaultFactorySpellCommon(asyncVaultFactory, syncDepositVaultFactory)
    {}

    function _getVaults() internal pure override returns (address[] memory) {
        address[] memory vaults = new address[](4);
        vaults[0] = VAULT_1;
        vaults[1] = VAULT_2;
        vaults[2] = VAULT_3;
        vaults[3] = VAULT_4;
        return vaults;
    }
}
