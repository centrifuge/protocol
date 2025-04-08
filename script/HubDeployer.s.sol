// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {TransientValuation} from "src/misc/TransientValuation.sol";
import {IdentityValuation} from "src/misc/IdentityValuation.sol";

import {ISafe} from "src/common/Guardian.sol";
import {Gateway} from "src/common/Gateway.sol";
import {Root} from "src/common/Root.sol";
import {GasService} from "src/common/GasService.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";

import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {HubRegistry} from "src/hub/HubRegistry.sol";
import {ShareClassManager} from "src/hub/ShareClassManager.sol";
import {Holdings} from "src/hub/Holdings.sol";
import {Accounting} from "src/hub/Accounting.sol";
import {Hub, IHub} from "src/hub/Hub.sol";
import {Hub} from "src/hub/Hub.sol";

import "forge-std/Script.sol";
import {CommonDeployer} from "script/CommonDeployer.s.sol";

contract HubDeployer is CommonDeployer {
    // Main contracts
    HubRegistry public hubRegistry;
    Accounting public accounting;
    Holdings public holdings;
    ShareClassManager public shareClassManager;
    Hub public hub;

    // Utilities
    TransientValuation public transientValuation;
    IdentityValuation public identityValuation;

    // Data
    AssetId public immutable USD = newAssetId(840);

    function deployPools(uint16 centrifugeId, ISafe adminSafe_, address deployer) public {
        deployCommon(centrifugeId, adminSafe_, deployer);

        hubRegistry = new HubRegistry(deployer);
        transientValuation = new TransientValuation(hubRegistry, deployer);
        identityValuation = new IdentityValuation(hubRegistry, deployer);
        accounting = new Accounting(deployer);
        holdings = new Holdings(hubRegistry, deployer);
        shareClassManager = new ShareClassManager(hubRegistry, deployer);
        hub = new Hub(shareClassManager, hubRegistry, accounting, holdings, gateway, transientValuation, deployer);

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
        register("transientValuation", address(transientValuation));
        register("identityValuation", address(identityValuation));
    }

    function _poolsRely() private {
        hubRegistry.rely(address(hub));
        holdings.rely(address(hub));
        accounting.rely(address(hub));
        shareClassManager.rely(address(hub));
        gateway.rely(address(hub));
        hub.rely(address(messageProcessor));
        hub.rely(address(messageDispatcher));
        hub.rely(address(guardian));
        messageDispatcher.rely(address(hub));
    }

    function _poolsFile() private {
        messageProcessor.file("hub", address(hub));
        messageDispatcher.file("hub", address(hub));

        hub.file("sender", address(messageDispatcher));

        guardian.file("hub", address(hub));
    }

    function _poolsInitialConfig() private {
        hubRegistry.registerAsset(USD, 18);
    }

    function removeHubDeployerAccess(address deployer) public {
        removeCommonDeployerAccess(deployer);

        hubRegistry.deny(deployer);
        accounting.deny(deployer);
        holdings.deny(deployer);
        shareClassManager.deny(deployer);
        hub.deny(deployer);

        transientValuation.deny(deployer);
        identityValuation.deny(deployer);
    }
}
