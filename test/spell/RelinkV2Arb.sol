// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RelinkV2Common} from "./RelinkV2Common.sol";

/// @notice Arbitrum-specific spell that relinks V2 vault to JTRSY token
contract RelinkV2Arb is RelinkV2Common {
    address public constant USDC_TOKEN = address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);

    address public constant JTRSY_VAULT_ADDRESS = address(0); // TODO

    function execute() internal override {
        // Relink JTRSY
        _relink(USDC_TOKEN, JTRSY_SHARE_TOKEN, JTRSY_VAULT_ADDRESS);

        // Final cleanup - deny spell's root permissions
        _cleanupRootPermissions();
    }
}
