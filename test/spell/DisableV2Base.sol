// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DisableV2Common} from "./DisableV2Common.sol";

import {IntegrationConstants} from "../integration/utils/IntegrationConstants.sol";

/// @notice Base network-specific spell that disables V2 permissions for JTRSY_USDC only
contract DisableV2Base is DisableV2Common {
    address public constant V2_JTRSY_VAULT_ADDRESS = IntegrationConstants.BASE_V2_JTRSY_VAULT;

    function getJTRSYVaultV2Address() internal pure override returns (address) {
        return V2_JTRSY_VAULT_ADDRESS;
    }
}
