// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";

import {TransientValuation} from "src/TransientValuation.sol";
import {OneToOneValuation} from "src/OneToOneValuation.sol";
import {PoolRegistry} from "src/PoolRegistry.sol";
import {Multicall} from "src/Multicall.sol";
import {SingleShareClass} from "src/SingleShareClass.sol";
import {Holdings} from "src/Holdings.sol";
//import {AssetManager} from "src/AssetManager.sol";
import {IAssetManager} from "src/interfaces/IAssetManager.sol"; // TODO: remove import
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
    IAssetManager public assetManager = IAssetManager(address(0));
    IAccounting public accounting = IAccounting(address(0));
    Holdings public holdings;
    SingleShareClass public singleShareClass;
    PoolManager public poolManager;
    IGateway public gateway = IGateway(address(0));

    function deploy(address deployer) public {
        // TODO: new AssetRegistry()
        // TODO: new Accounting()
        // TODO: new Gateway()

        transientValuation = new TransientValuation(assetManager, deployer);
        oneToOneValuation = new OneToOneValuation(assetManager, deployer);

        poolRegistry = new PoolRegistry(deployer);
        holdings = new Holdings(poolRegistry, deployer);
        singleShareClass = new SingleShareClass(poolRegistry, deployer);

        multicall = new Multicall();
        poolManager = new PoolManager(multicall, poolRegistry, assetManager, accounting, holdings, gateway, deployer);

        poolRegistry.rely(address(poolManager));
        //assetManager.rely(address(poolManager));
        holdings.rely(address(poolManager));
        //accounting.rely(address(accounting));
        singleShareClass.rely(address(poolManager));
        //gateway.rely(address(poolManager));

        poolManager.rely(address(gateway));
    }
}
