// Network: Arbitrum (Chain ID: 42161)
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {VaultPermissionSpell} from "./VaultPermissionSpell.sol";

import {IShareToken} from "../../src/spoke/interfaces/IShareToken.sol";

/**
 * @title VaultPermissionSpellArbitrum
 * @notice Arbitrum-specific implementation of the VaultPermissionSpell
 *         Handles the v2 JTRSY vault relinking on Arbitrum network
 */
contract VaultPermissionSpellArbitrum is VaultPermissionSpell {
    address public constant JTRSY_V2_VAULT_ADDRESS = 0x16C796208c6E2d397Ec49D69D207a9cB7d072f04;

    address public constant USDC_TOKEN = address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IShareToken public constant JTRSY_SHARE_TOKEN = IShareToken(0x8c213ee79581Ff4984583C6a801e5263418C4b86);

    constructor(address newAsyncRequestManager, address newAsyncVaultFactory, address newSyncDepositVaultFactory)
        VaultPermissionSpell(newAsyncRequestManager, newAsyncVaultFactory, newSyncDepositVaultFactory)
    {}

    function _relinkV2Vaults() internal override {
        ROOT.relyContract(address(JTRSY_SHARE_TOKEN), address(this));
        JTRSY_SHARE_TOKEN.updateVault(USDC_TOKEN, JTRSY_V2_VAULT_ADDRESS);
        ROOT.denyContract(address(JTRSY_SHARE_TOKEN), address(this));
    }
}