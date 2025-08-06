// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ForkTestVaultMigrationCommon} from "./ForkTestVaultMigrationCommon.sol";

import {IntegrationConstants} from "../utils/IntegrationConstants.sol";
import {VaultMigrationSpellCommon} from "../../../env/spell/VaultMigrationSpellCommon.sol";
import {VaultMigrationSpellEthereum} from "../../../env/spell/VaultMigrationSpellEthereum.sol";

/// @notice Fork test for VaultMigrationSpellEthereum spell execution
contract ForkTestEthereumVaultMigration is ForkTestVaultMigrationCommon {
    VaultMigrationSpellEthereum public ethereumSpell;

    /// @notice Get the RPC URL for Ethereum
    function _rpcEndpoint() internal pure override returns (string memory) {
        return IntegrationConstants.RPC_ETHEREUM;
    }

    /// @notice Get the spell instance for Ethereum
    function _getSpell() internal view override returns (VaultMigrationSpellCommon) {
        return VaultMigrationSpellCommon(address(ethereumSpell));
    }

    /// @notice Get old vault addresses from spell (single source of truth)
    function _getOldVaults() internal view override returns (address[] memory) {
        address[] memory vaults = new address[](3);
        vaults[0] = ethereumSpell.VAULT_1();
        vaults[1] = ethereumSpell.VAULT_2();
        vaults[2] = ethereumSpell.VAULT_3();
        return vaults;
    }

    /// @notice Ethereum supports async flows (hub and spoke on same chain)
    function _shouldTestAsyncFlows() internal pure override returns (bool) {
        return true;
    }

    //----------------------------------------------------------------------------------------------
    // SETUP & CONFIGURATION
    //----------------------------------------------------------------------------------------------

    function setUp() public override {
        super.setUp();

        // Create Ethereum-specific spell with factory addresses
        ethereumSpell = new VaultMigrationSpellEthereum(asyncVaultFactory, syncDepositVaultFactory);
        spell = VaultMigrationSpellCommon(address(ethereumSpell));

        _configureChain(IntegrationConstants.ETH_CENTRIFUGE_ID, IntegrationConstants.ETH_ADMIN_SAFE);
    }
}
