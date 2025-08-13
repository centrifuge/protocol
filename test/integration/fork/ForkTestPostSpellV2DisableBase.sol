// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ForkTestPostSpellV2DisableCommon} from "./ForkTestPostSpellV2DisableCommon.sol";

import {DisableV2Base} from "../../spell/DisableV2Base.sol";
import {DisableV2Common} from "../../spell/DisableV2Common.sol";
import {IntegrationConstants} from "../utils/IntegrationConstants.sol";

/// @notice Base network fork test validating DisableV2Base spell execution and post-spell V2/V3 state
contract ForkTestPostSpellV2DisableBase is ForkTestPostSpellV2DisableCommon {
    function _rpcEndpoint() internal pure override returns (string memory) {
        return IntegrationConstants.RPC_BASE;
    }

    function _createSpell() internal override returns (DisableV2Common) {
        return new DisableV2Base();
    }

    function _configureNetwork() internal override {
        localCentrifugeId = _centrifugeId();
        adminSafe = _adminSafe();
    }

    // Non-Ethereum networks don't have hub == spoke chain vaults
    function _canTestAsyncFlow() internal pure override returns (bool) {
        return false;
    }

    function _validateV2OperationsDisabled() internal override {
        _validateV2VaultOperationsFail(_jtrsyVaultAddress());
    }

    function _validatePostSpellPermissions() internal view override {
        super._validatePostSpellPermissions();
        _validateVaultPermissions(_jtrsyVaultAddress(), spell.JTRSY_SHARE_TOKEN(), "JTRSY");
    }

    function _centrifugeId() internal pure override returns (uint16) {
        return IntegrationConstants.BASE_CENTRIFUGE_ID;
    }

    function _adminSafe() internal pure override returns (address) {
        return IntegrationConstants.BASE_ADMIN_SAFE;
    }

    function _jtrsyVaultAddress() internal view override returns (address) {
        return DisableV2Base(address(spell)).V2_JTRSY_VAULT_ADDRESS();
    }
}
