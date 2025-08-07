// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ForkTestCreate2VaultFactoryCommon} from "./ForkTestCreate2VaultFactoryCommon.sol";

import {IntegrationConstants} from "../utils/IntegrationConstants.sol";
import {Create2VaultFactorySpellBase} from "../../spell/Create2VaultFactorySpellBase.sol";
import {Create2VaultFactorySpellWithMigration} from "../../spell/Create2VaultFactorySpellWithMigration.sol";

/// @notice Fork test for Create2VaultFactorySpellBase spell execution
/// @dev Base vaults have their hub on Ethereum, so async investment flows cannot work
///      with current infrastructure (assumes same-chain). Skips async flows for Base.
contract ForkTestCreate2VaultFactoryBase is ForkTestCreate2VaultFactoryCommon {
    Create2VaultFactorySpellBase public baseSpell;

    function _rpcEndpoint() internal pure override returns (string memory) {
        return IntegrationConstants.RPC_BASE;
    }

    function _getSpell() internal view override returns (Create2VaultFactorySpellWithMigration) {
        return Create2VaultFactorySpellWithMigration(address(baseSpell));
    }

    function _getOldVaults() internal view override returns (address[] memory) {
        address[] memory vaults = new address[](1);
        vaults[0] = baseSpell.VAULT_1();
        return vaults;
    }

    /// @notice Flow does not support hub (ethereum) chain != spoke (base) chain
    function _shouldTestAsyncFlows() internal pure override returns (bool) {
        return false;
    }

    //----------------------------------------------------------------------------------------------
    // SETUP & CONFIGURATION
    //----------------------------------------------------------------------------------------------

    function setUp() public override {
        super.setUp();

        baseSpell = new Create2VaultFactorySpellBase(asyncVaultFactory, syncDepositVaultFactory);
        spell = Create2VaultFactorySpellWithMigration(address(baseSpell));

        _configureChain(IntegrationConstants.BASE_CENTRIFUGE_ID, IntegrationConstants.BASE_ADMIN_SAFE);
    }

    /// @notice Flow does not support hub (ethereum) chain != spoke (base) chain
    function test_completeAsyncDepositFlow() public override {}

    /// @notice Flow does not support hub (ethereum) chain != spoke (base) chain
    function test_completeAsyncRedeemFlow() public override {}
}
