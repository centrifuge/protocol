// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";

import {TransientValuation} from "src/misc/TransientValuation.sol";
import {IdentityValuation} from "src/misc/IdentityValuation.sol";

import {Gateway} from "src/common/Gateway.sol";

import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
import {IAdapter} from "src/pools/interfaces/IAdapter.sol";
import {PoolRegistry} from "src/pools/PoolRegistry.sol";
import {SingleShareClass} from "src/pools/SingleShareClass.sol";
import {Holdings} from "src/pools/Holdings.sol";
import {AssetRegistry} from "src/pools/AssetRegistry.sol";
import {Accounting} from "src/pools/Accounting.sol";
import {MessageProcessor} from "src/pools/MessageProcessor.sol";
import {PoolManager, IPoolManager} from "src/pools/PoolManager.sol";
import {PoolRouter} from "src/pools/PoolRouter.sol";

contract Deployer is Script {
    // Core contracts
    PoolRegistry public poolRegistry;
    AssetRegistry public assetRegistry;
    Accounting public accounting;
    Holdings public holdings;
    SingleShareClass public singleShareClass;
    Gateway public gateway;
    PoolManager public poolManager;
    MessageProcessor public messageProcessor;
    PoolRouter public poolRouter;

    // Utilities
    TransientValuation public transientValuation;
    IdentityValuation public identityValuation;

    // Data
    AssetId immutable USD = newAssetId(840);

    function deploy() public {
        poolRegistry = new PoolRegistry(address(this));
        assetRegistry = new AssetRegistry(address(this));
        accounting = new Accounting(address(this));
        holdings = new Holdings(poolRegistry, address(this));
        singleShareClass = new SingleShareClass(poolRegistry, address(this));
        gateway = new Gateway(address(this));
        poolManager = new PoolManager(poolRegistry, assetRegistry, accounting, holdings, gateway, address(this));
        messageProcessor = new MessageProcessor(gateway, poolManager, address(this));
        poolRouter = new PoolRouter(poolManager);

        transientValuation = new TransientValuation(assetRegistry, address(this));
        identityValuation = new IdentityValuation(assetRegistry, address(this));

        _file();
        _rely();
        _initialConfig();
    }

    function _file() private {
        poolManager.file("sender", address(messageProcessor));
        gateway.file("handle", address(messageProcessor));
    }

    function _rely() private {
        poolRegistry.rely(address(poolManager));
        assetRegistry.rely(address(poolManager));
        holdings.rely(address(poolManager));
        accounting.rely(address(poolManager));
        singleShareClass.rely(address(poolManager));
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
        singleShareClass.deny(address(this));
        gateway.deny(address(this));
        messageProcessor.deny(address(this));
        poolManager.deny(address(this));

        transientValuation.deny(address(this));
        identityValuation.deny(address(this));
    }
}
