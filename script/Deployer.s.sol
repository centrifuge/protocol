// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";

import {AssetId, newAssetIdFromISO4217} from "src/types/AssetId.sol";

import {TransientValuation} from "src/TransientValuation.sol";
import {OneToOneValuation} from "src/OneToOneValuation.sol";
import {PoolRegistry} from "src/PoolRegistry.sol";
import {Multicall} from "src/Multicall.sol";
import {SingleShareClass} from "src/SingleShareClass.sol";
import {Holdings} from "src/Holdings.sol";
import {AssetManager} from "src/AssetManager.sol";
//import {Accounting} from "src/Accounting.sol";
import {IAccounting} from "src/interfaces/IAccounting.sol"; // TODO: remove import
//import {Gateway} from "src/Gateway.sol";
import {IGateway} from "src/interfaces/IGateway.sol"; // TODO: remove import
import {PoolManager, IPoolManager} from "src/PoolManager.sol";

contract Deployer is Script {
    // Utilities
    TransientValuation public transientValuation;
    OneToOneValuation public oneToOneValuation;

    // Core contracts
    Multicall public multicall;
    PoolRegistry public poolRegistry;
    AssetManager public assetManager;
    IAccounting public accounting = IAccounting(address(0));
    Holdings public holdings;
    SingleShareClass public singleShareClass;
    PoolManager public poolManager;
    IGateway public gateway = IGateway(address(0));

    // Data
    AssetId immutable USD = newAssetIdFromISO4217(840);

    function deploy() public {
        multicall = new Multicall();

        transientValuation = new TransientValuation(assetManager, address(this));
        oneToOneValuation = new OneToOneValuation(assetManager, address(this));

        poolRegistry = new PoolRegistry(address(this));
        assetManager = new AssetManager(address(this));
        // TODO: initialize Accounting
        holdings = new Holdings(poolRegistry, address(this));

        singleShareClass = new SingleShareClass(poolRegistry, address(this));
        poolManager =
            new PoolManager(multicall, poolRegistry, assetManager, accounting, holdings, gateway, address(this));
        // TODO: initialize Gateway

        _rely();
        _initialConfig();
    }

    function _rely() private {
        poolRegistry.rely(address(poolManager));
        assetManager.rely(address(poolManager));
        holdings.rely(address(poolManager));
        //accounting.rely(address(accounting));
        singleShareClass.rely(address(poolManager));
        poolManager.rely(address(gateway));
        //gateway.rely(address(poolManager));
    }

    function _initialConfig() private {
        assetManager.registerAsset(USD, "United States dollar", "USD", 18);
    }

    function removeDeployerAccess() public {
        transientValuation.deny(address(this));
        oneToOneValuation.deny(address(this));
        poolRegistry.deny(address(this));
        assetManager.deny(address(this));
        // TODO: deny accounting
        holdings.deny(address(this));
        singleShareClass.deny(address(this));
        poolManager.deny(address(this));
        // TODO: deny gateway
    }
}
