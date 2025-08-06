// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ForkTestVaultMigrationCommon} from "./ForkTestVaultMigrationCommon.sol";

import {IntegrationConstants} from "../utils/IntegrationConstants.sol";
import {VaultMigrationSpellCommon} from "../../../env/spell/VaultMigrationSpellCommon.sol";
import {VaultMigrationSpellAvalanche} from "../../../env/spell/VaultMigrationSpellAvalanche.sol";

/// @notice Fork test for VaultMigrationSpellAvalanche spell execution
/// @dev Avalanche vaults have their hub on Ethereum, so async investment flows cannot work
///      with current infrastructure (assumes same-chain). Skips async flows for Avalanche.
contract ForkTestAvalancheVaultMigration is ForkTestVaultMigrationCommon {
    VaultMigrationSpellAvalanche public avalancheSpell;

    function _rpcEndpoint() internal pure override returns (string memory) {
        return IntegrationConstants.RPC_AVALANCHE;
    }

    function _getSpell() internal view override returns (VaultMigrationSpellCommon) {
        return VaultMigrationSpellCommon(address(avalancheSpell));
    }

    function _getOldVaults() internal view override returns (address[] memory) {
        address[] memory vaults = new address[](2);
        vaults[0] = avalancheSpell.VAULT_1();
        vaults[1] = avalancheSpell.VAULT_2();
        return vaults;
    }

    /// @notice Flow does not support hub (ethereum) chain != spoke (avalanche) chain
    function _shouldTestAsyncFlows() internal pure override returns (bool) {
        return false;
    }

    //----------------------------------------------------------------------------------------------
    // SETUP & CONFIGURATION
    //----------------------------------------------------------------------------------------------

    function setUp() public override {
        super.setUp();

        avalancheSpell = new VaultMigrationSpellAvalanche(asyncVaultFactory, syncDepositVaultFactory);
        spell = VaultMigrationSpellCommon(address(avalancheSpell));

        _configureChain(IntegrationConstants.AVAX_CENTRIFUGE_ID, IntegrationConstants.AVAX_ADMIN_SAFE);
    }

    /// @notice Flow does not support hub (ethereum) chain != spoke (avalanche) chain
    function test_completeAsyncDepositFlow() public override {}

    /// @notice Flow does not support hub (ethereum) chain != spoke (avalanche) chain
    function test_completeAsyncRedeemFlow() public override {}
}
