// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";

import {TransientValuation} from "src/misc/TransientValuation.sol";
import {IdentityValuation} from "src/misc/IdentityValuation.sol";

import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
import {IGateway} from "src/pools/interfaces/IGateway.sol";
import {IAdapter} from "src/pools/interfaces/IAdapter.sol";
import {PoolRegistry} from "src/pools/PoolRegistry.sol";
import {SingleShareClass} from "src/pools/SingleShareClass.sol";
import {Holdings} from "src/pools/Holdings.sol";
import {AssetRegistry} from "src/pools/AssetRegistry.sol";
import {Accounting} from "src/pools/Accounting.sol";
import {Gateway} from "src/pools/Gateway.sol";
import {PoolManager, IPoolManager} from "src/pools/PoolManager.sol";
import {PoolRouter} from "src/pools/PoolRouter.sol";

contract Deployer is Script {
    /// @dev Identifies an address that requires to be overwritten by a `file()` method before ending the deployment.
    /// Just a placesholder and visual indicator.
    address constant ADDRESS_TO_FILE = address(123);

    // Core contracts
    PoolRegistry public poolRegistry;
    AssetRegistry public assetRegistry;
    Accounting public accounting;
    Holdings public holdings;
    SingleShareClass public singleShareClass;
    PoolManager public poolManager;
    Gateway public gateway;
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
        poolManager =
            new PoolManager(poolRegistry, assetRegistry, accounting, holdings, IGateway(ADDRESS_TO_FILE), address(this));
        gateway = new Gateway(IAdapter(address(0 /* TODO */ )), poolManager, address(this));
        poolRouter = new PoolRouter(poolManager);

        transientValuation = new TransientValuation(assetRegistry, address(this));
        identityValuation = new IdentityValuation(assetRegistry, address(this));

        _file();
        _rely();
        _initialConfig();
    }

    function _file() public {
        poolManager.file("gateway", address(gateway));
    }

    function _rely() private {
        poolRegistry.rely(address(poolManager));
        assetRegistry.rely(address(poolManager));
        holdings.rely(address(poolManager));
        accounting.rely(address(poolManager));
        singleShareClass.rely(address(poolManager));
        poolManager.rely(address(gateway));
        poolManager.rely(address(poolRouter));
        gateway.rely(address(poolManager));
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
        poolManager.deny(address(this));
        gateway.deny(address(this));

        transientValuation.deny(address(this));
        identityValuation.deny(address(this));
    }
}
