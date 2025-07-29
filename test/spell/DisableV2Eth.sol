// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

import {DisableV2Common} from "./DisableV2Common.sol";

/// @notice Ethereum-specific spell that disables V2 permissions for both JTRSY_USDC and JAAA_USDC
contract DisableV2Eth is DisableV2Common {
    // JAAA configuration (only exists on Ethereum mainnet)
    IShareToken public constant JAAA_SHARE_TOKEN = IShareToken(0x5a0F93D040De44e78F251b03c43be9CF317Dcf64);

    address public constant JTRSY_VAULT_ADDRESS = address(0x36036fFd9B1C6966ab23209E073c68Eb9A992f50);
    address public constant JAAA_VAULT_ADDRESS = address(0xE9d1f733F406D4bbbDFac6D4CfCD2e13A6ee1d01);

    function getJTRSYVaultAddress() internal pure override returns (address) {
        return JTRSY_VAULT_ADDRESS;
    }

    function execute() internal override {
        // Disable V2 permissions and set V3 hook for JTRSY
        _disableV2Permissions(JTRSY_SHARE_TOKEN, getJTRSYVaultAddress());
        _setV3Hook(JTRSY_SHARE_TOKEN);

        // Disable V2 permissions and set V3 hook for JAAA (Ethereum only)
        _disableV2Permissions(JAAA_SHARE_TOKEN, JAAA_VAULT_ADDRESS);
        _setV3Hook(JAAA_SHARE_TOKEN);

        // Final cleanup - deny spell's root permissions
        _cleanupRootPermissions();
    }
}
