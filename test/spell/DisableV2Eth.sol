// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DisableV2Common} from "./DisableV2Common.sol";

import {IntegrationConstants} from "../integration/utils/IntegrationConstants.sol";

/// @notice Ethereum-specific spell that disables V2 permissions for both JTRSY_USDC and JAAA_USDC
contract DisableV2Eth is DisableV2Common {
    // V2 vault addresses (Ethereum-only)
    address public constant V2_JTRSY_VAULT_ADDRESS = IntegrationConstants.ETH_V2_JTRSY_VAULT;
    address public constant V2_JAAA_VAULT_ADDRESS = IntegrationConstants.ETH_V2_JAAA_VAULT;

    // JAAA V3 constants (Ethereum-only)
    address public constant V3_JAAA_VAULT = 0x4880799eE5200fC58DA299e965df644fBf46780B;

    function getJTRSYVaultV2Address() internal pure override returns (address) {
        return V2_JTRSY_VAULT_ADDRESS;
    }

    function execute() internal override {
        // JTRSY V2 disable + V3 setup (from parent, but without cleanup)
        _disableV2Permissions(JTRSY_SHARE_TOKEN, getJTRSYVaultV2Address());
        _setV3Hook(JTRSY_SHARE_TOKEN);
        _linkTokenToV3Vault(JTRSY_SHARE_TOKEN, V3_JTRSY_VAULT, JTRSY_POOL_ID, JTRSY_SHARE_CLASS_ID);

        // JAAA V2 disable + V3 setup (Ethereum-specific)
        _disableV2Permissions(JAAA_SHARE_TOKEN, V2_JAAA_VAULT_ADDRESS);
        _setV3Hook(JAAA_SHARE_TOKEN);
        _linkTokenToV3Vault(JAAA_SHARE_TOKEN, V3_JAAA_VAULT, JAAA_POOL_ID, JAAA_SHARE_CLASS_ID);

        // Clean up permissions AFTER all operations
        _cleanupRootPermissions();
    }
}
