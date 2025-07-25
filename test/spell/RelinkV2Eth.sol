// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

import {RelinkV2Common} from "./RelinkV2Common.sol";

/// @notice Ethereum-specific spell that relinks V2 vaults to JTRSY and JAAA token
contract RelinkV2Eth is RelinkV2Common {
    IShareToken public constant JAAA_SHARE_TOKEN = IShareToken(0x5a0F93D040De44e78F251b03c43be9CF317Dcf64);

    address public constant USDC_TOKEN = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    address public constant JTRSY_VAULT_ADDRESS = address(0x1d01Ef1997d44206d839b78bA6813f60F1B3A970);
    address public constant JAAA_VAULT_ADDRESS = address(0xE9d1f733F406D4bbbDFac6D4CfCD2e13A6ee1d01);

    function execute() internal override {
        // Relink JTRSY and JAAAA
        _relink(USDC_TOKEN, JTRSY_SHARE_TOKEN, JTRSY_VAULT_ADDRESS);
        _relink(USDC_TOKEN, JAAA_SHARE_TOKEN, JAAA_VAULT_ADDRESS);

        // Final cleanup - deny spell's root permissions
        _cleanupRootPermissions();
    }
}
