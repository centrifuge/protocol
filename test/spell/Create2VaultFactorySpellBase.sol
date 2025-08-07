// Network: Base (Chain ID: 8453)
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Create2VaultFactorySpellWithMigration} from "./Create2VaultFactorySpellWithMigration.sol";

/**
 * @title Create2VaultFactorySpellBase
 * @notice Base-specific governance spell to migrate 1 collision vault to CREATE2 deployment
 * @dev Extends Create2VaultFactorySpellWithMigration to resolve cross-chain address collisions
 */
contract Create2VaultFactorySpellBase is Create2VaultFactorySpellWithMigration {
    // deJAAA Base USDC Vault
    address public constant VAULT_1 = 0x2D38c58Cc7d4DdD6B4DaF7b3539902a7667F4519;

    constructor(address asyncVaultFactory, address syncDepositVaultFactory)
        Create2VaultFactorySpellWithMigration(asyncVaultFactory, syncDepositVaultFactory)
    {}

    function _getVaults() internal pure override returns (address[] memory) {
        address[] memory vaults = new address[](1);
        vaults[0] = VAULT_1;
        return vaults;
    }
}
