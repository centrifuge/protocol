// Network: Avalanche (Chain ID: 43114)
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Create2VaultFactorySpellCommon} from "./Create2VaultFactorySpellCommon.sol";

/**
 * @title Create2VaultFactorySpellAvalanche
 * @notice Avalanche-specific governance spell to migrate 2 collision vaults to CREATE2 deployment
 * @dev Extends Create2VaultFactorySpellCommon to resolve cross-chain address collisions
 */
contract Create2VaultFactorySpellAvalanche is Create2VaultFactorySpellCommon {
    // deJTRSY Avalanche USDC Vault (COLLISION with deJTRSY ETH JTRSY)
    address public constant VAULT_1 = 0x04157759a9fe406d82a16BdEB20F9BeB9bBEb958;

    // deJAAA Avalanche USDC Vault (COLLISION with deJTRSY ETH USDC)
    address public constant VAULT_2 = 0xCF4C60066aAB54b3f750F94c2a06046d5466Ccf9;

    constructor(address asyncVaultFactory, address syncDepositVaultFactory)
        Create2VaultFactorySpellCommon(asyncVaultFactory, syncDepositVaultFactory)
    {}

    function _getVaults() internal pure override returns (address[] memory) {
        address[] memory vaults = new address[](2);
        vaults[0] = VAULT_1;
        vaults[1] = VAULT_2;
        return vaults;
    }
}
