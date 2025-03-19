// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";

import {TransientValuation} from "src/misc/TransientValuation.sol";
import {IdentityValuation} from "src/misc/IdentityValuation.sol";

import {Gateway} from "src/common/Gateway.sol";
import {Root} from "src/common/Root.sol";
import {GasService} from "src/common/GasService.sol";
import {CommonDeployer} from "script/CommonDeployer.s.sol";
import {ISafe} from "src/common/Guardian.sol";

import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
import {PoolRegistry} from "src/pools/PoolRegistry.sol";
import {MultiShareClass} from "src/pools/MultiShareClass.sol";
import {Holdings} from "src/pools/Holdings.sol";
import {AssetRegistry} from "src/pools/AssetRegistry.sol";
import {Accounting} from "src/pools/Accounting.sol";
import {MessageProcessor} from "src/pools/MessageProcessor.sol";
import {PoolRouter, IPoolRouter} from "src/pools/PoolRouter.sol";
import {PoolRouter} from "src/pools/PoolRouter.sol";

contract PoolsDeployer is CommonDeployer {
    // Main contracts
    Gateway public gateway;
    PoolRegistry public poolRegistry;
    AssetRegistry public assetRegistry;
    Accounting public accounting;
    Holdings public holdings;
    MultiShareClass public multiShareClass;
    PoolRouter public poolRouter;
    MessageProcessor public messageProcessor;

    // Utilities
    TransientValuation public transientValuation;
    IdentityValuation public identityValuation;

    // Data
    AssetId immutable USD = newAssetId(840);

    function deployPools(ISafe adminSafe_, address deployer) public {
        super.deployCommon(adminSafe_, deployer);

        gateway = new Gateway(root, gasService);
        poolRegistry = new PoolRegistry(deployer);
        assetRegistry = new AssetRegistry(deployer);
        accounting = new Accounting(deployer);
        holdings = new Holdings(poolRegistry, deployer);
        multiShareClass = new MultiShareClass(poolRegistry, deployer);
        poolRouter = new PoolRouter(poolRegistry, assetRegistry, accounting, holdings, gateway, deployer);
        messageProcessor = new MessageProcessor(gateway, poolRouter, deployer);

        transientValuation = new TransientValuation(assetRegistry, deployer);
        identityValuation = new IdentityValuation(assetRegistry, deployer);

        _file();
        _rely();
        _initialConfig();
    }

    function _file() private {
        poolRouter.file("sender", address(messageProcessor));
        gateway.file("handler", address(messageProcessor));
    }

    function _rely() private {
        poolRegistry.rely(address(poolRouter));
        assetRegistry.rely(address(poolRouter));
        holdings.rely(address(poolRouter));
        accounting.rely(address(poolRouter));
        multiShareClass.rely(address(poolRouter));
        gateway.rely(address(poolRouter));
        gateway.rely(address(messageProcessor));
        poolRouter.rely(address(messageProcessor));
        messageProcessor.rely(address(poolRouter));
        messageProcessor.rely(address(gateway));
    }

    function _initialConfig() private {
        assetRegistry.registerAsset(USD, "United States dollar", "USD", 18);
    }

    function removeDeployerAccess(address deployer) public {
        super.removeCommonDeployerAccess(deployer);

        poolRegistry.deny(deployer);
        assetRegistry.deny(deployer);
        accounting.deny(deployer);
        holdings.deny(deployer);
        multiShareClass.deny(deployer);
        gateway.deny(deployer);
        messageProcessor.deny(deployer);
        poolRouter.deny(deployer);

        transientValuation.deny(deployer);
        identityValuation.deny(deployer);
    }
}
