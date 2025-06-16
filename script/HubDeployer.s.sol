// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IdentityValuation} from "src/misc/IdentityValuation.sol";

import {ISafe} from "src/common/Guardian.sol";
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";

import {Hub} from "src/hub/Hub.sol";
import {Holdings} from "src/hub/Holdings.sol";
import {Accounting} from "src/hub/Accounting.sol";
import {HubHelpers} from "src/hub/HubHelpers.sol";
import {HubRegistry} from "src/hub/HubRegistry.sol";
import {ShareClassManager} from "src/hub/ShareClassManager.sol";

import {CommonDeployer} from "script/CommonDeployer.s.sol";

import "forge-std/Script.sol";

contract HubDeployer is CommonDeployer {
    // Main contracts
    HubRegistry public hubRegistry;
    Accounting public accounting;
    Holdings public holdings;
    ShareClassManager public shareClassManager;
    HubHelpers public hubHelpers;
    Hub public hub;

    // Utilities
    IdentityValuation public identityValuation;

    // Data
    uint8 constant ISO4217_DECIMALS = 18;
    AssetId public immutable USD_ID = newAssetId(840);
    AssetId public immutable EUR_ID = newAssetId(978);

    function deployHub(uint16 centrifugeId, ISafe adminSafe_, address deployer, bool isTests) public {
        deployCommon(centrifugeId, adminSafe_, deployer, isTests);

        hubRegistry = new HubRegistry(deployer);
        identityValuation = new IdentityValuation(hubRegistry, deployer);
        accounting = new Accounting(deployer);
        holdings = new Holdings(hubRegistry, deployer);
        shareClassManager = new ShareClassManager(hubRegistry, deployer);
        hubHelpers = new HubHelpers(holdings, accounting, hubRegistry, messageDispatcher, shareClassManager, deployer);
        hub = new Hub(gateway, holdings, hubHelpers, accounting, hubRegistry, shareClassManager, deployer);

        _poolsRegister();
        _poolsRely();
        _poolsFile();
        _poolsInitialConfig();
    }

    function _poolsRegister() private {
        register("hubRegistry", address(hubRegistry));
        register("accounting", address(accounting));
        register("holdings", address(holdings));
        register("shareClassManager", address(shareClassManager));
        register("hub", address(hub));
        register("identityValuation", address(identityValuation));
    }

    function _poolsRely() private {
        // Rely hub
        hubRegistry.rely(address(hub));
        holdings.rely(address(hub));
        accounting.rely(address(hub));
        shareClassManager.rely(address(hub));
        gateway.rely(address(hub));
        messageDispatcher.rely(address(hub));
        hubHelpers.rely(address(hub));
        poolEscrowFactory.rely(address(hub));

        // Rely hub helpers
        accounting.rely(address(hubHelpers));
        shareClassManager.rely(address(hubHelpers));
        messageDispatcher.rely(address(hubHelpers));

        // Rely others on hub
        hub.rely(address(messageProcessor));
        hub.rely(address(messageDispatcher));
        hub.rely(address(guardian));

        // Rely root
        hubRegistry.rely(address(root));
        accounting.rely(address(root));
        holdings.rely(address(root));
        shareClassManager.rely(address(root));
        hub.rely(address(root));
        identityValuation.rely(address(root));
        hubHelpers.rely(address(root));
    }

    function _poolsFile() private {
        messageProcessor.file("hub", address(hub));
        messageDispatcher.file("hub", address(hub));

        hub.file("sender", address(messageDispatcher));
        hub.file("poolEscrowFactory", address(poolEscrowFactory));

        guardian.file("hub", address(hub));

        hubHelpers.file("hub", address(hub));
    }

    function _poolsInitialConfig() private {
        hubRegistry.registerAsset(USD_ID, ISO4217_DECIMALS);
        hubRegistry.registerAsset(EUR_ID, ISO4217_DECIMALS);
    }

    function removeHubDeployerAccess(address deployer) public {
        removeCommonDeployerAccess(deployer);

        hubRegistry.deny(deployer);
        accounting.deny(deployer);
        holdings.deny(deployer);
        shareClassManager.deny(deployer);
        hub.deny(deployer);
        hubHelpers.deny(deployer);
        identityValuation.deny(deployer);
    }
}
