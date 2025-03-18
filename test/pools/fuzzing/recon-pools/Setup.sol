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
import "src/pools/MultiShareClass.sol";
import "src/pools/interfaces/IPoolRegistry.sol";
import "src/pools/interfaces/IAssetRegistry.sol";
import "src/pools/interfaces/IAccounting.sol";
import "src/pools/interfaces/IHoldings.sol";
import "src/pools/interfaces/IPoolManager.sol";
import "src/common/interfaces/IMessageSender.sol";
import "src/common/interfaces/IGasService.sol";
import "src/common/interfaces/IGateway.sol";
import "src/misc/TransientValuation.sol";
import "src/misc/IdentityValuation.sol";
import "src/pools/MessageProcessor.sol";
import "src/common/Root.sol";
import "test/common/mocks/MockAdapter.sol";
import "test/common/mocks/MockGasService.sol";
import "test/pools/fuzzing/recon-pools/mocks/MockGateway.sol";

abstract contract Setup is BaseSetup, ActorManager, AssetManager, Utils {
    Accounting accounting;
    AssetRegistry assetRegistry;
    // Gateway gateway;
    Holdings holdings;
    PoolManager poolManager;
    PoolRegistry poolRegistry;
    PoolRouter poolRouter;
    MultiShareClass multiShareClass;
    MessageProcessor messageProcessor;
    TransientValuation transientValuation;
    IdentityValuation identityValuation;
    Root root;

    MockAdapter mockAdapter;
    MockGasService gasService;
    MockGateway gateway;

    bytes[] internal queuedCalls; // used for storing calls to PoolRouter to be executed in a single transaction
    PoolId[] internal createdPools;

    // Canaries
    bool poolCreated;
    bool deposited;
    bool cancelledRedeemRequest;

    // set the initial price that gets used when creating an asset via a pool's shortcut to avoid stack too deep errors
    D18 internal INITIAL_PRICE = d18(1e18); 

    event LogString(string);
    
    /// === Setup === ///
    /// This contains all calls to be performed in the tester constructor, both for Echidna and Foundry
    function setup() internal virtual override {
        // add two actors in addition to the default admin (address(this))
        _addActor(address(0x10000));
        _addActor(address(0x20000));

        gateway = new MockGateway();
        gasService = new MockGasService();
        root = new Root(7 days, address(this));
        accounting = new Accounting(address(this)); 
        assetRegistry = new AssetRegistry(address(this)); 
        poolRegistry = new PoolRegistry(address(this)); 

        holdings = new Holdings(IPoolRegistry(address(poolRegistry)), address(this));
        poolManager = new PoolManager(IPoolRegistry(address(poolRegistry)), IAssetRegistry(address(assetRegistry)), IAccounting(address(accounting)), IHoldings(address(holdings)), address(this));
        poolRouter = new PoolRouter(IPoolManager(address(poolManager)), IGateway(address(gateway)));
        multiShareClass = new MultiShareClass(IPoolRegistry(address(poolRegistry)), address(this));
        messageProcessor = new MessageProcessor(IMessageSender(address(gateway)), poolManager, address(this));

        mockAdapter = new MockAdapter(IMessageHandler(address(gateway)));

        transientValuation = new TransientValuation(assetRegistry, address(this));
        identityValuation = new IdentityValuation(assetRegistry, address(this));

        // set addresses on the PoolManager and Gateway
        poolManager.file("sender", address(messageProcessor));
        gateway.file("handler", address(messageProcessor));
        gateway.file("gasService", address(gasService));
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = IAdapter(address(mockAdapter));
        gateway.file("adapters", adapters);

        // set permissions for calling privileged functions
        poolRegistry.rely(address(poolManager));
        assetRegistry.rely(address(poolManager));
        accounting.rely(address(poolManager));
        holdings.rely(address(poolManager));
        multiShareClass.rely(address(poolManager));
        poolManager.rely(address(poolRouter));
        messageProcessor.rely(address(poolManager));
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
