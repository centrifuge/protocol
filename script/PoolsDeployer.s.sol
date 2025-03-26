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
import {PoolRouter, IPoolRouter} from "src/pools/PoolRouter.sol";
import {PoolRouter} from "src/pools/PoolRouter.sol";

import "forge-std/Script.sol";
import {CommonDeployer} from "script/CommonDeployer.s.sol";

contract PoolsDeployer is CommonDeployer {
    // Main contracts
    PoolRegistry public poolRegistry;
    AssetRegistry public assetRegistry;
    Accounting public accounting;
    Holdings public holdings;
    MultiShareClass public multiShareClass;
    PoolRouter public poolRouter;

    // Utilities
    TransientValuation public transientValuation;
    IdentityValuation public identityValuation;

    // Data
    AssetId public immutable USD = newAssetId(840);

    function deployPools(uint16 chainId, ISafe adminSafe_) public {
        deployCommon(chainId, adminSafe_);

        poolRegistry = new PoolRegistry(address(this));
        assetRegistry = new AssetRegistry(address(this));
        transientValuation = new TransientValuation(assetRegistry, address(this));
        identityValuation = new IdentityValuation(assetRegistry, address(this));
        accounting = new Accounting(address(this));
        holdings = new Holdings(poolRegistry, address(this));
        multiShareClass = new MultiShareClass(poolRegistry, address(this));
        poolRouter =
            new PoolRouter(poolRegistry, assetRegistry, accounting, holdings, gateway, transientValuation, address(this));

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
        register("poolRouter", address(poolRouter));
        register("transientValuation", address(transientValuation));
        register("identityValuation", address(identityValuation));
    }

    function _poolsRely() private {
        poolRegistry.rely(address(poolRouter));
        assetRegistry.rely(address(poolRouter));
        holdings.rely(address(poolRouter));
        accounting.rely(address(poolRouter));
        multiShareClass.rely(address(poolRouter));
        gateway.rely(address(poolRouter));
        poolRouter.rely(address(messageProcessor));
        messageProcessor.rely(address(poolRouter));
    }

    function _poolsFile() private {
        messageProcessor.file("poolRouter", address(poolRouter));
        poolRouter.file("sender", address(messageProcessor));
    }

    function _poolsInitialConfig() private {
        assetRegistry.registerAsset(USD, "United States dollar", "USD", 18);
    }

    function removePoolsDeployerAccess() public {
        removeCommonDeployerAccess();

        poolRegistry.deny(address(this));
        assetRegistry.deny(address(this));
        accounting.deny(address(this));
        holdings.deny(address(this));
        multiShareClass.deny(address(this));
        poolRouter.deny(address(this));

        transientValuation.deny(address(this));
        identityValuation.deny(address(this));
    }
}
