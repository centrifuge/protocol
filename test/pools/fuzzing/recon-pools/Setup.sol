// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {BaseSetup} from "@chimera/BaseSetup.sol";
import {vm} from "@chimera/Hevm.sol";
import {console2} from "forge-std/console2.sol";

// Recon Helpers
import {ActorManager} from "@recon/ActorManager.sol";
import {AssetManager} from "@recon/AssetManager.sol";
import {Utils} from "@recon/Utils.sol";

// Dependencies
import {Accounting} from "src/hub/Accounting.sol";
import {HubRegistry} from "src/hub/HubRegistry.sol";
import {Gateway} from "src/common/Gateway.sol";
import {Holdings} from "src/hub/Holdings.sol";
import {HubRegistry} from "src/hub/HubRegistry.sol";
import {Hub} from "src/hub/Hub.sol";
import {ShareClassManager} from "src/hub/ShareClassManager.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {TransientValuation, ITransientValuation} from "src/misc/TransientValuation.sol";
import {IdentityValuation} from "src/misc/IdentityValuation.sol";
import {MessageProcessor} from "src/common/MessageProcessor.sol";
import {Root} from "src/common/Root.sol";
import {MockAdapter} from "test/common/mocks/MockAdapter.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

// Interfaces
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {IAccounting} from "src/hub/interfaces/IAccounting.sol";
import {IHoldings} from "src/hub/interfaces/IHoldings.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";
import {IAsyncRequests} from "src/vaults/interfaces/investments/IAsyncRequests.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IAccounting} from "src/hub/interfaces/IAccounting.sol";

// Types
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {D18, d18} from "src/misc/types/D18.sol";

// Test Utils
import {MockGateway} from "test/pools/fuzzing/recon-pools/mocks/MockGateway.sol";
import {ShareClassManagerWrapper} from "test/pools/fuzzing/recon-pools/utils/ShareClassManagerWrapper.sol";
import {MockMessageDispatcher} from "test/vaults/fuzzing/recon-core/mocks/MockMessageDispatcher.sol";
import {MockAccountValue} from "test/pools/fuzzing/recon-pools/mocks/MockAccountValue.sol";

abstract contract Setup is BaseSetup, ActorManager, AssetManager, Utils {
    enum Op {
        APPROVE_DEPOSITS,
        APPROVE_REDEEMS,
        REVOKE_SHARES
    }

    struct QueuedOp {
        Op op;
        ShareClassId scId;
    }

    Accounting accounting;
    HubRegistry hubRegistry;
    Holdings holdings;
    Hub hub;
    ShareClassManagerWrapper shareClassManager;
    TransientValuation transientValuation;
    IdentityValuation identityValuation;
    Root root;

    MockAdapter mockAdapter;
    MockGateway gateway;
    MockMessageDispatcher messageDispatcher;
    MockAccountValue mockAccountValue;

    bytes[] internal queuedCalls; // used for storing calls to PoolRouter to be executed in a single transaction
    PoolId[] internal createdPools;
    // QueuedOp[] internal queuedOps;

    // Canaries
    bool poolCreated;
    bool deposited;
    bool cancelledRedeemRequest;

    D18 internal INITIAL_PRICE = d18(1e18); // set the initial price that gets used when creating an asset via a pool's shortcut to avoid stack too deep errors
    uint16 internal CENTIFUGE_CHAIN_ID = 1;
    /// @dev see toggle_IsLiability
    bool internal IS_LIABILITY = true; 
    /// @dev see toggle_IsIncrease
    bool internal IS_INCREASE = true;
    /// @dev see toggle_AccountToUpdate
    uint8 internal ACCOUNT_TO_UPDATE = 0;

    event LogString(string);

    modifier stateless {
        _;
        revert("stateless");
    }

    /// @dev Clear queued calls so they don't interfere with executions in shortcut functions 
    modifier clearQueuedCalls {
        queuedCalls = new bytes[](0);
        _;
    }
    
    /// === Setup === ///
    /// This contains all calls to be performed in the tester constructor, both for Echidna and Foundry
    function setup() internal virtual override {
        // add two actors in addition to the default admin (address(this))
        _addActor(address(0x10000));
        _addActor(address(0x20000));

        gateway = new MockGateway();
        root = new Root(7 days, address(this));
        accounting = new Accounting(address(this)); 
        hubRegistry = new HubRegistry(address(this)); 
        transientValuation = new TransientValuation(hubRegistry, address(this));
        identityValuation = new IdentityValuation(hubRegistry, address(this));
        mockAdapter = new MockAdapter(CENTIFUGE_CHAIN_ID, IMessageHandler(address(gateway)));
        mockAccountValue = new MockAccountValue();

        holdings = new Holdings(IHubRegistry(address(hubRegistry)), address(this));
        shareClassManager = new ShareClassManagerWrapper(IHubRegistry(address(hubRegistry)), address(this));
        messageDispatcher = new MockMessageDispatcher(PoolManager(address(this)), IAsyncRequests(address(this)), root, CENTIFUGE_CHAIN_ID);
        hub = new Hub(
            IShareClassManager(address(shareClassManager)), 
            IHubRegistry(address(hubRegistry)), 
            IAccounting(address(accounting)), 
            IHoldings(address(holdings)), 
            IGateway(address(gateway)), 
            ITransientValuation(address(transientValuation)), 
            address(this)
        );

        // set addresses on the PoolRouter
        hub.file("sender", address(messageDispatcher));

        // set permissions for calling privileged functions
        hubRegistry.rely(address(hub));
        accounting.rely(address(hub));
        holdings.rely(address(hub));
        shareClassManager.rely(address(hub));
        hub.rely(address(hub));
        shareClassManager.rely(address(this));
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

    /// === Helpers === ///
    function _getRandomPoolId(uint64 poolEntropy) internal view returns (PoolId) {
        return createdPools[poolEntropy % createdPools.length];
    }

    function _getRandomShareClassIdForPool(PoolId poolId, uint32 scEntropy) internal view returns (ShareClassId) {
        uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
        uint32 randomIndex = scEntropy % shareClassCount;
        if(randomIndex == 0) {
            // the first share class is never assigned
            randomIndex = 1;
        }

        ShareClassId scId = shareClassManager.previewShareClassId(poolId, randomIndex);
        return scId;
    }

    function _getRandomAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 accountEntropy) internal view returns (AccountId) {
        uint8 accountType = accountEntropy % 6;
        return holdings.accountId(poolId, scId, assetId, accountType);
    }

    function _checkIfCanCancel(uint32 lastUpdate, uint128 pending, uint128 latestApproval) internal pure returns (bool) {
        return lastUpdate > latestApproval || pending == 0 || latestApproval == 0;
    }
}
