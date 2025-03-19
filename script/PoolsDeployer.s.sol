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

import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
import {PoolRegistry} from "src/pools/PoolRegistry.sol";
import {MultiShareClass} from "src/pools/MultiShareClass.sol";
import {Holdings} from "src/pools/Holdings.sol";
import {AssetRegistry} from "src/pools/AssetRegistry.sol";
import {Accounting} from "src/pools/Accounting.sol";
import {MessageProcessor} from "src/pools/MessageProcessor.sol";
import {PoolRouter, IPoolRouter} from "src/pools/PoolRouter.sol";
import {PoolRouter} from "src/pools/PoolRouter.sol";

import "forge-std/Script.sol";
import {CommonDeployer} from "script/CommonDeployer.s.sol";

contract PoolsDeployer is CommonDeployer {
    IAdapter[] poolAdapters;

    // Main contracts
    Gateway public poolGateway;
    PoolRegistry public poolRegistry;
    AssetRegistry public assetRegistry;
    Accounting public accounting;
    Holdings public holdings;
    MultiShareClass public multiShareClass;
    PoolRouter public poolRouter;
    MessageProcessor public poolMessageProcessor;

    // Utilities
    TransientValuation public transientValuation;
    IdentityValuation public identityValuation;

    // Data
    AssetId immutable USD = newAssetId(840);

    function deployPools(ISafe adminSafe_, address deployer) public {
        super.deployCommon(adminSafe_, deployer);

        poolGateway = new Gateway(root, gasService);
        poolRegistry = new PoolRegistry(deployer);
        assetRegistry = new AssetRegistry(deployer);
        accounting = new Accounting(deployer);
        holdings = new Holdings(poolRegistry, deployer);
        multiShareClass = new MultiShareClass(poolRegistry, deployer);
        poolRouter = new PoolRouter(poolRegistry, assetRegistry, accounting, holdings, poolGateway, deployer);
        poolMessageProcessor = new MessageProcessor(poolGateway, poolRouter, deployer);

        transientValuation = new TransientValuation(assetRegistry, deployer);
        identityValuation = new IdentityValuation(assetRegistry, deployer);

        _poolsFile();
        _poolsRely();
        _poolsInitialConfig();
    }

    function _poolsFile() private {
        poolRouter.file("sender", address(poolMessageProcessor));
        poolGateway.file("handler", address(poolMessageProcessor));
    }

    function _poolsRely() private {
        poolRegistry.rely(address(poolRouter));
        assetRegistry.rely(address(poolRouter));
        holdings.rely(address(poolRouter));
        accounting.rely(address(poolRouter));
        multiShareClass.rely(address(poolRouter));
        poolGateway.rely(address(poolRouter));
        poolGateway.rely(address(poolMessageProcessor));
        poolRouter.rely(address(poolMessageProcessor));
        poolMessageProcessor.rely(address(poolRouter));
        poolMessageProcessor.rely(address(poolGateway));
    }

    function _poolsInitialConfig() private {
        assetRegistry.registerAsset(USD, "United States dollar", "USD", 18);
    }

    function wirePoolAdapter(IAdapter adapter, address deployer) public {
        poolAdapters.push(adapter);
        poolGateway.file("adapters", poolAdapters);
        IAuth(address(adapter)).rely(address(root));
        IAuth(address(adapter)).deny(deployer);
    }

    function removePoolsDeployerAccess(address deployer) public {
        super.removeCommonDeployerAccess(deployer);

        poolRegistry.deny(deployer);
        assetRegistry.deny(deployer);
        accounting.deny(deployer);
        holdings.deny(deployer);
        multiShareClass.deny(deployer);
        poolGateway.deny(deployer);
        poolMessageProcessor.deny(deployer);
        poolRouter.deny(deployer);

        transientValuation.deny(deployer);
        identityValuation.deny(deployer);
    }
}
