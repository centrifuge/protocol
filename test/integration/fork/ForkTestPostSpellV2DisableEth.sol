// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ForkTestPostSpellV2DisableCommon} from "./ForkTestPostSpellV2DisableCommon.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";

import {DisableV2Eth} from "../../spell/DisableV2Eth.sol";
import {DisableV2Common} from "../../spell/DisableV2Common.sol";
import {IntegrationConstants} from "../utils/IntegrationConstants.sol";

/// @notice Ethereum network fork test validating DisableV2Eth spell execution and post-spell V2/V3 state
contract ForkTestPostSpellV2DisableEth is ForkTestPostSpellV2DisableCommon {
    function _rpcEndpoint() internal pure override returns (string memory) {
        return IntegrationConstants.RPC_ETHEREUM;
    }

    function _createSpell() internal override returns (DisableV2Common) {
        return new DisableV2Eth();
    }

    function _canTestLocalAsyncFlow() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        localCentrifugeId = _centrifugeId();
        adminSafe = _adminSafe();
    }

    function _centrifugeId() internal pure override returns (uint16) {
        return IntegrationConstants.ETH_CENTRIFUGE_ID;
    }

    function _adminSafe() internal pure override returns (address) {
        return IntegrationConstants.ETH_ADMIN_SAFE;
    }

    function _ethSpell() internal view returns (DisableV2Eth) {
        return DisableV2Eth(address(spell));
    }

    function _validateContractAddresses() internal view override {
        super._validateContractAddresses();
        DisableV2Eth ethSpell = _ethSpell();

        assertTrue(ethSpell.V2_JTRSY_VAULT_ADDRESS().code.length > 0, "JTRSY V2 Vault should have code");
        assertTrue(ethSpell.V2_JAAA_VAULT_ADDRESS().code.length > 0, "JAAA V2 Vault should have code");
        assertTrue(ethSpell.V3_JAAA_VAULT().code.length > 0, "JAAA V3 Vault should have code");
        assertTrue(address(ethSpell.JAAA_SHARE_TOKEN()).code.length > 0, "JAAA Share Token should have code");
    }

    function test_jaaa_vaultAsyncFlowsPostSpell() public {
        DisableV2Eth ethSpell = _ethSpell();

        completeAsyncDepositLocal(IBaseVault(ethSpell.V3_JAAA_VAULT()), investor, depositAmount);
        completeAsyncRedeemLocal(IBaseVault(ethSpell.V3_JAAA_VAULT()), investor, depositAmount);
    }

    function _validateV2OperationsDisabled() internal override {
        DisableV2Eth ethSpell = _ethSpell();

        _validateV2VaultOperationsFail(ethSpell.V2_JTRSY_VAULT_ADDRESS());
        _validateV2VaultOperationsFail(ethSpell.V2_JAAA_VAULT_ADDRESS());
    }

    function _validatePostSpellPermissions() internal view override {
        super._validatePostSpellPermissions();
        DisableV2Eth ethSpell = _ethSpell();

        _validateVaultPermissions(ethSpell.V2_JTRSY_VAULT_ADDRESS(), spell.JTRSY_SHARE_TOKEN(), "JTRSY");
        _validateVaultPermissions(ethSpell.V2_JAAA_VAULT_ADDRESS(), ethSpell.JAAA_SHARE_TOKEN(), "JAAA");
    }

    function _validateRootPermissionsIntact() internal view override {
        assertFalse(spell.V2_ROOT().paused(), "V2 root should not be paused");
        assertFalse(spell.V3_ROOT().paused(), "V3 root should not be paused");
    }
}
