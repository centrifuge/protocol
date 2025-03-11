// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {BaseSetup} from "@chimera/BaseSetup.sol";
import {vm} from "@chimera/Hevm.sol";

// Managers
import {ActorManager} from "@recon/ActorManager.sol";
import {AssetManager} from "@recon/AssetManager.sol";

// Helpers
import {Utils} from "@recon/Utils.sol";

// Your deps
import "src/pools/Accounting.sol";
import "src/pools/AssetRegistry.sol";
import "src/common/Gateway.sol";
import "src/pools/Holdings.sol";
import "src/pools/PoolManager.sol";
import "src/pools/PoolRegistry.sol";
import "src/pools/PoolRouter.sol";
import "src/pools/SingleShareClass.sol";
import "src/pools/interfaces/IPoolRegistry.sol";
import "src/pools/interfaces/IAssetRegistry.sol";
import "src/pools/interfaces/IAccounting.sol";
import "src/pools/interfaces/IHoldings.sol";
import "src/common/interfaces/IGateway.sol";
import "src/pools/interfaces/IPoolManager.sol";
import "src/misc/TransientValuation.sol";
import "src/misc/IdentityValuation.sol";

abstract contract Setup is BaseSetup, ActorManager, AssetManager, Utils {
    Accounting accounting;
    AssetRegistry assetRegistry;
    Gateway gateway;
    Holdings holdings;
    PoolManager poolManager;
    PoolRegistry poolRegistry;
    PoolRouter poolRouter;
    SingleShareClass singleShareClass;
    TransientValuation transientValuation;
    IdentityValuation identityValuation;
    
    /// === Setup === ///
    /// This contains all calls to be performed in the tester constructor, both for Echidna and Foundry
    function setup() internal virtual override {
        accounting = new Accounting(address(this)); 
        assetRegistry = new AssetRegistry(address(this)); 
        gateway = new Gateway(address(this));
        poolRegistry = new PoolRegistry(address(this)); 

        holdings = new Holdings(IPoolRegistry(address(poolRegistry)), address(this));
        poolManager = new PoolManager(IPoolRegistry(address(poolRegistry)), IAssetRegistry(address(assetRegistry)), IAccounting(address(accounting)), IHoldings(address(holdings)), IGateway(address(gateway)), address(this));
        poolRouter = new PoolRouter(IPoolManager(address(poolManager)));
        singleShareClass = new SingleShareClass(IPoolRegistry(address(poolRegistry)), address(this));

        transientValuation = new TransientValuation(assetRegistry, address(this));
        identityValuation = new IdentityValuation(assetRegistry, address(this));

        poolRegistry.rely(address(poolManager));
        assetRegistry.rely(address(poolManager));
        accounting.rely(address(poolManager));
        holdings.rely(address(poolManager));
        gateway.rely(address(poolManager));
        singleShareClass.rely(address(poolManager));
        poolManager.rely(address(poolRouter));

    }

    /// === MODIFIERS === ///
    /// Prank admin and actor
    
    modifier asAdmin {
        vm.prank(address(this));
        _;
    }

    modifier asActor {
        vm.prank(address(_getActor()));
        _;
    }
}
