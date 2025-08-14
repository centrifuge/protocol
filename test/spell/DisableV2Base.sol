// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DisableV2Common} from "./DisableV2Common.sol";

import {AssetId} from "../../src/common/types/AssetId.sol";
import {VaultUpdateKind} from "../../src/common/libraries/MessageLib.sol";
import {IRequestManager} from "../../src/common/interfaces/IRequestManager.sol";
import {ISpokeGatewayHandler, IBalanceSheetGatewayHandler} from "../../src/common/interfaces/IGatewayHandlers.sol";

import {IntegrationConstants} from "../integration/utils/IntegrationConstants.sol";

/// @notice Base network-specific spell that disables V2 permissions for both JTRSY_USDC and JAAA_USDC
/// @dev Also deploys V3 JAAA vault on Base spoke
contract DisableV2Base is DisableV2Common {
    // V2 vault addresses
    address public constant V2_JTRSY_VAULT_ADDRESS = IntegrationConstants.BASE_V2_JTRSY_VAULT;
    address public constant V2_JAAA_VAULT_ADDRESS = 0xB4C8540657d67D4846cAe68EcfE2C706c80DC3c9;

    // V3 network constants for JAAA vault deployment
    address public constant V3_ASYNC_VAULT_FACTORY = IntegrationConstants.ASYNC_VAULT_FACTORY;
    address public constant V3_ASYNC_REQUEST_MANAGER = IntegrationConstants.ASYNC_REQUEST_MANAGER;
    address public constant V3_BALANCE_SHEET = IntegrationConstants.BALANCE_SHEET;
    AssetId public constant V3_BASE_USDC_ASSET_ID = AssetId.wrap(10384593717069655257060992658440193);

    function getJTRSYVaultV2Address() internal pure override returns (address) {
        return V2_JTRSY_VAULT_ADDRESS;
    }

    function execute() internal override {
        // JTRSY V2 disable + V3 setup (inherited logic)
        _disableV2Permissions(JTRSY_SHARE_TOKEN, getJTRSYVaultV2Address());
        _setV3Hook(JTRSY_SHARE_TOKEN);
        _linkTokenToV3Vault(JTRSY_SHARE_TOKEN, V3_JTRSY_VAULT, JTRSY_POOL_ID, JTRSY_SHARE_CLASS_ID);

        // JAAA rely V3 contracts
        _relyJaaaShareTokenV3Contracts();

        // JAAA V2 disable + V3 setup (Base-specific)
        _disableV2Permissions(JAAA_SHARE_TOKEN, V2_JAAA_VAULT_ADDRESS);
        _setV3Hook(JAAA_SHARE_TOKEN);

        // Deploy V3 JAAA vault on Base spoke
        _deployBaseV3JaaaVault();

        // Clean up permissions AFTER all operations
        _cleanupRootPermissions();
    }

    function _relyJaaaShareTokenV3Contracts() internal {
        V2_ROOT.relyContract(address(JAAA_SHARE_TOKEN), address(V3_ROOT));
        V2_ROOT.relyContract(address(JAAA_SHARE_TOKEN), V3_BALANCE_SHEET);
        V2_ROOT.relyContract(address(JAAA_SHARE_TOKEN), address(V3_SPOKE));
    }

    function _deployBaseV3JaaaVault() internal {
        ISpokeGatewayHandler spokeHandler = ISpokeGatewayHandler(address(V3_SPOKE));

        V3_ROOT.relyContract(address(V3_SPOKE), address(this));

        V3_SPOKE.linkToken(JAAA_POOL_ID, JAAA_SHARE_CLASS_ID, JAAA_SHARE_TOKEN);
        spokeHandler.setRequestManager(
            JAAA_POOL_ID, JAAA_SHARE_CLASS_ID, V3_BASE_USDC_ASSET_ID, IRequestManager(V3_ASYNC_REQUEST_MANAGER)
        );
        spokeHandler.updateVault(
            JAAA_POOL_ID,
            JAAA_SHARE_CLASS_ID,
            V3_BASE_USDC_ASSET_ID,
            V3_ASYNC_VAULT_FACTORY,
            VaultUpdateKind.DeployAndLink
        );

        V3_ROOT.denyContract(address(V3_SPOKE), address(this));

        // Update balance sheet manager for JAAA pool to use async request manager
        V3_ROOT.relyContract(V3_BALANCE_SHEET, address(this));
        IBalanceSheetGatewayHandler(V3_BALANCE_SHEET).updateManager(JAAA_POOL_ID, V3_ASYNC_REQUEST_MANAGER, true);
        V3_ROOT.denyContract(V3_BALANCE_SHEET, address(this));
    }
}
