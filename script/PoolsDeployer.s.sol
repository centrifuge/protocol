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
import {PoolRegistry} from "src/pools/PoolRegistry.sol";
import {MultiShareClass} from "src/pools/MultiShareClass.sol";
import {Holdings} from "src/pools/Holdings.sol";
import {AssetRegistry} from "src/pools/AssetRegistry.sol";
import {Accounting} from "src/pools/Accounting.sol";
import {Hub, IHub} from "src/pools/Hub.sol";
import {Hub} from "src/pools/Hub.sol";

import "forge-std/Script.sol";
import {CommonDeployer} from "script/CommonDeployer.s.sol";

contract PoolsDeployer is CommonDeployer {
    // Main contracts
    PoolRegistry public poolRegistry;
    AssetRegistry public assetRegistry;
    Accounting public accounting;
    Holdings public holdings;
    MultiShareClass public multiShareClass;
    Hub public hub;

    // Utilities
    TransientValuation public transientValuation;
    IdentityValuation public identityValuation;

    // Data
    AssetId public immutable USD = newAssetId(840);

    function deployPools(uint16 chainId, ISafe adminSafe_, address deployer) public {
        deployCommon(chainId, adminSafe_, deployer);

        poolRegistry = new PoolRegistry(deployer);
        assetRegistry = new AssetRegistry(deployer);
        transientValuation = new TransientValuation(assetRegistry, deployer);
        identityValuation = new IdentityValuation(assetRegistry, deployer);
        accounting = new Accounting(deployer);
        holdings = new Holdings(poolRegistry, deployer);
        multiShareClass = new MultiShareClass(poolRegistry, deployer);
        hub = new Hub(poolRegistry, assetRegistry, accounting, holdings, gateway, transientValuation, deployer);

        _poolsRegister();
        _poolsRely();
        _poolsFile();
        _poolsInitialConfig();
    }

    function _poolsRegister() private {
        register("poolRegistry", address(poolRegistry));
        register("assetRegistry", address(assetRegistry));
        register("accounting", address(accounting));
        register("holdings", address(holdings));
        register("multiShareClass", address(multiShareClass));
        register("hub", address(hub));
        register("transientValuation", address(transientValuation));
        register("identityValuation", address(identityValuation));
    }

    function _poolsRely() private {
        poolRegistry.rely(address(hub));
        assetRegistry.rely(address(hub));
        holdings.rely(address(hub));
        accounting.rely(address(hub));
        multiShareClass.rely(address(hub));
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
        guardian.file("assetRegistry", address(assetRegistry));
    }

    function _poolsInitialConfig() private {
        assetRegistry.registerAsset(USD, "United States dollar", "USD", 18);
    }

    function removePoolsDeployerAccess(address deployer) public {
        removeCommonDeployerAccess(deployer);

        poolRegistry.deny(deployer);
        assetRegistry.deny(deployer);
        accounting.deny(deployer);
        holdings.deny(deployer);
        multiShareClass.deny(deployer);
        hub.deny(deployer);

        transientValuation.deny(deployer);
        identityValuation.deny(deployer);
    }
}
