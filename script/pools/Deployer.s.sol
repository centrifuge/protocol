// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";

import {TransientValuation} from "src/misc/TransientValuation.sol";
import {OneToOneValuation} from "src/misc/OneToOneValuation.sol";
import {Multicall} from "src/misc/Multicall.sol";

import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
import {IGateway} from "src/pools/interfaces/IGateway.sol";
import {IAdapter} from "src/pools/interfaces/IAdapter.sol";
import {PoolRegistry} from "src/pools/PoolRegistry.sol";
import {SingleShareClass} from "src/pools/SingleShareClass.sol";
import {Holdings} from "src/pools/Holdings.sol";
import {AssetManager} from "src/pools/AssetManager.sol";
import {Accounting} from "src/pools/Accounting.sol";
import {Gateway} from "src/pools/Gateway.sol";
import {PoolManager, IPoolManager} from "src/pools/PoolManager.sol";

contract Deployer is Script {
    /// @dev Identifies an address that requires to be overwritten by a `file()` method before ending the deployment.
    /// Just a placesholder and visual indicator.
    address constant ADDRESS_TO_FILE = address(123);

    // Core contracts
    Multicall public multicall;
    PoolRegistry public poolRegistry;
    AssetManager public assetManager;
    Accounting public accounting;
    Holdings public holdings;
    SingleShareClass public singleShareClass;
    PoolManager public poolManager;
    Gateway public gateway;

    // Utilities
    TransientValuation public transientValuation;
    OneToOneValuation public oneToOneValuation;

    // Data
    AssetId immutable USD = newAssetId(840);

    function deploy() public {
        multicall = new Multicall();

        poolRegistry = new PoolRegistry(address(this));
        assetManager = new AssetManager(address(this));
        accounting = new Accounting(address(this));
        holdings = new Holdings(poolRegistry, address(this));

        singleShareClass = new SingleShareClass(poolRegistry, address(this));
        poolManager = new PoolManager(
            multicall, poolRegistry, assetManager, accounting, holdings, IGateway(ADDRESS_TO_FILE), address(this)
        );
        gateway = new Gateway(IAdapter(address(0 /* TODO */ )), poolManager, address(this));

        transientValuation = new TransientValuation(assetManager, address(this));
        oneToOneValuation = new OneToOneValuation(assetManager, address(this));

        _file();
        _rely();
        _initialConfig();
    }

    function _file() public {
        poolManager.file("gateway", address(gateway));
    }

    function _rely() private {
        poolRegistry.rely(address(poolManager));
        assetManager.rely(address(poolManager));
        holdings.rely(address(poolManager));
        accounting.rely(address(poolManager));
        singleShareClass.rely(address(poolManager));
        poolManager.rely(address(gateway));
        gateway.rely(address(poolManager));
    }

    function _initialConfig() private {
        assetManager.registerAsset(USD, "United States dollar", "USD", 18);
    }

    function removeDeployerAccess() public {
        poolRegistry.deny(address(this));
        assetManager.deny(address(this));
        accounting.deny(address(this));
        holdings.deny(address(this));
        singleShareClass.deny(address(this));
        poolManager.deny(address(this));
        gateway.deny(address(this));

        transientValuation.deny(address(this));
        oneToOneValuation.deny(address(this));
    }
}
