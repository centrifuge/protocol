// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DisableV2Common} from "./DisableV2Common.sol";

/// @notice Arbitrum-specific spell that disables V2 permissions for JTRSY_USDC only
contract DisableV2Arb is DisableV2Common {
    address public constant JTRSY_VAULT_ADDRESS = address(0xe98Cf1221bC3F38D8bb132b8434A6F8885071173);

    function getJTRSYVaultAddress() internal pure override returns (address) {
        return JTRSY_VAULT_ADDRESS;
    }
}
