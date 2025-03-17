// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";

import {TransientValuation} from "src/misc/TransientValuation.sol";
import {IdentityValuation} from "src/misc/IdentityValuation.sol";

import {Gateway} from "src/common/Gateway.sol";
import {Root} from "src/common/Root.sol";
import {GasService} from "src/common/GasService.sol";

import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
import {PoolRegistry} from "src/pools/PoolRegistry.sol";
import {MultiShareClass} from "src/pools/MultiShareClass.sol";
import {Holdings} from "src/pools/Holdings.sol";
import {AssetRegistry} from "src/pools/AssetRegistry.sol";
import {Accounting} from "src/pools/Accounting.sol";
import {MessageProcessor} from "src/pools/MessageProcessor.sol";
import {PoolManager, IPoolManager} from "src/pools/PoolManager.sol";
import {PoolRouter} from "src/pools/PoolRouter.sol";

contract Deployer is Script {
    uint256 internal constant delay = 48 hours;

    // Common contracts
    Root public root;
    GasService public gasService;
    Gateway public gateway;

    // Pools contracts
    PoolRegistry public poolRegistry;
    AssetRegistry public assetRegistry;
    Accounting public accounting;
    Holdings public holdings;
    MultiShareClass public multiShareClass;
    PoolManager public poolManager;
    MessageProcessor public messageProcessor;
    PoolRouter public poolRouter;

    // Utilities
    TransientValuation public transientValuation;
    IdentityValuation public identityValuation;

    // Data
    AssetId immutable USD = newAssetId(840);

    function deploy() public {
        root = new Root(delay, address(this));
        gasService = new GasService(0, 0); // TODO: Configure properly
        gateway = new Gateway(root, gasService);

        poolRegistry = new PoolRegistry(address(this));
        assetRegistry = new AssetRegistry(address(this));
        accounting = new Accounting(address(this));
        holdings = new Holdings(poolRegistry, address(this));
        multiShareClass = new MultiShareClass(poolRegistry, address(this));
        poolManager = new PoolManager(poolRegistry, assetRegistry, accounting, holdings, address(this));
        messageProcessor = new MessageProcessor(gateway, poolManager, address(this));
        poolRouter = new PoolRouter(poolManager, gateway);

        transientValuation = new TransientValuation(assetRegistry, address(this));
        identityValuation = new IdentityValuation(assetRegistry, address(this));

        _file();
        _rely();
        _initialConfig();
    }

    function _file() private {
        poolManager.file("sender", address(messageProcessor));
        gateway.file("handler", address(messageProcessor));
    }

    function _rely() private {
        poolRegistry.rely(address(poolManager));
        assetRegistry.rely(address(poolManager));
        holdings.rely(address(poolManager));
        accounting.rely(address(poolManager));
        multiShareClass.rely(address(poolManager));
        gateway.rely(address(poolManager));
        gateway.rely(address(messageProcessor));
        poolManager.rely(address(messageProcessor));
        poolManager.rely(address(poolRouter));
        messageProcessor.rely(address(poolManager));
        messageProcessor.rely(address(gateway));
    }

    function _initialConfig() private {
        assetRegistry.registerAsset(USD, "United States dollar", "USD", 18);
    }

    function removeDeployerAccess() public {
        poolRegistry.deny(address(this));
        assetRegistry.deny(address(this));
        accounting.deny(address(this));
        holdings.deny(address(this));
        multiShareClass.deny(address(this));
        gateway.deny(address(this));
        messageProcessor.deny(address(this));
        poolManager.deny(address(this));

        transientValuation.deny(address(this));
        identityValuation.deny(address(this));
    }
}
