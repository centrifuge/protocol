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
import {Spoke} from "src/spoke/Spoke.sol";
import {MockValuation} from "test/common/mocks/MockValuation.sol";
import {IdentityValuation} from "src/misc/IdentityValuation.sol";
import {MessageProcessor} from "src/common/MessageProcessor.sol";
import {Root} from "src/common/Root.sol";
import {MockAdapter} from "test/common/mocks/MockAdapter.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {HubHelpers} from "src/hub/HubHelpers.sol";

// Interfaces
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {IAccounting} from "src/hub/interfaces/IAccounting.sol";
import {IHoldings} from "src/hub/interfaces/IHoldings.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";
import {IHubMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IAccounting} from "src/hub/interfaces/IAccounting.sol";
import {IERC6909Decimals} from "src/misc/interfaces/IERC6909.sol";
import {IHubHelpers} from "src/hub/interfaces/IHubHelpers.sol";

// Types
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {PoolEscrowFactory} from "src/common/factories/PoolEscrowFactory.sol";
import {D18, d18} from "src/misc/types/D18.sol";

// Test Utils
import {MockGateway} from "test/integration/recon-end-to-end/mocks/MockGateway.sol";
import {MockMessageDispatcher} from "test/integration/recon-end-to-end/mocks/MockMessageDispatcher.sol";
import {MockAccountValue} from "test/hub/fuzzing/recon-hub/mocks/MockAccountValue.sol";
import {MockAsyncRequestManager} from "test/vaults/fuzzing/recon-core/mocks/MockAsyncRequestManager.sol";
import {MockSpoke} from "test/hub/fuzzing/recon-hub/mocks/MockSpoke.sol";
import {MockBalanceSheet} from "test/hub/fuzzing/recon-hub/mocks/MockBalanceSheet.sol";

abstract contract Setup is BaseSetup, ActorManager, AssetManager, Utils {
    Accounting accounting;
    HubRegistry hubRegistry;
    Holdings holdings;
    Hub hub;
    ShareClassManager shareClassManager;
    MockValuation transientValuation;
    IdentityValuation identityValuation;
    Root root;
    HubHelpers hubHelpers;
    MockAdapter mockAdapter;
    MockGateway gateway;
    MockMessageDispatcher messageDispatcher;
    MockAccountValue mockAccountValue;
    MockAsyncRequestManager requestManager;
    MockSpoke spoke;
    MockBalanceSheet balanceSheet;
    PoolEscrowFactory poolEscrowFactory;

    bytes[] internal queuedCalls; // used for storing calls to PoolRouter to be executed in a single transaction
    PoolId[] internal createdPools;
    AccountId[] internal createdAccountIds;
    AssetId[] internal createdAssetIds;

    // Canaries
    bool poolCreated;
    bool deposited;
    bool cancelledRedeemRequest;

    D18 internal INITIAL_PRICE = d18(1e18); // set the initial price that gets used when creating an asset via a pool's
        // shortcut to avoid stack too deep errors
    uint16 internal CENTIFUGE_CHAIN_ID = 1;
    /// @dev see toggle_IsLiability
    bool internal IS_LIABILITY = true;
    /// @dev see toggle_IsIncrease
    bool internal IS_INCREASE = true;
    bool internal IS_DEBIT_NORMAL = true;
    bool internal IS_SNAPSHOT = false;
    uint64 internal NONCE = 0;
    uint32 internal MAX_CLAIMS = 10;
    /// @dev see toggle_AccountToUpdate
    AccountId internal ACCOUNT_TO_UPDATE = AccountId.wrap(0);
    uint32 internal ASSET_ACCOUNT = 1;
    uint32 internal EQUITY_ACCOUNT = 2;
    uint32 internal LOSS_ACCOUNT = 3;
    uint32 internal GAIN_ACCOUNT = 4;
    uint64 internal POOL_ID_COUNTER = 1;

    event LogString(string);

    modifier statelessTest() {
        _;
        revert("stateless");
    }

    /// @dev Clear queued calls so they don't interfere with executions in shortcut functions
    modifier clearQueuedCalls() {
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
        transientValuation = new MockValuation(IERC6909Decimals(address(hubRegistry)));
        identityValuation = new IdentityValuation(IERC6909Decimals(address(hubRegistry)), address(this));
        mockAdapter = new MockAdapter(CENTIFUGE_CHAIN_ID, IMessageHandler(address(gateway)));
        mockAccountValue = new MockAccountValue();
        requestManager = new MockAsyncRequestManager();
        spoke = new MockSpoke();
        balanceSheet = new MockBalanceSheet();
        holdings = new Holdings(IHubRegistry(address(hubRegistry)), address(this));

        shareClassManager = new ShareClassManager(IHubRegistry(address(hubRegistry)), address(this));
        hubHelpers = new HubHelpers(
            IHoldings(address(holdings)),
            IAccounting(address(accounting)),
            IHubRegistry(address(hubRegistry)),
            IHubMessageSender(address(messageDispatcher)),
            IShareClassManager(address(shareClassManager)),
            address(this)
        );
        messageDispatcher = new MockMessageDispatcher();
        hub = new Hub(
            IGateway(address(gateway)),
            IHoldings(address(holdings)),
            IHubHelpers(address(hubHelpers)),
            IAccounting(address(accounting)),
            IHubRegistry(address(hubRegistry)),
            IShareClassManager(address(shareClassManager)),
            address(this)
        );
        poolEscrowFactory = new PoolEscrowFactory(address(root), address(this));

        // set permissions for calling privileged functions
        hubRegistry.rely(address(hub));
        holdings.rely(address(hub));
        accounting.rely(address(hub));
        shareClassManager.rely(address(hub));
        poolEscrowFactory.rely(address(hub));

        // Rely hub helpers
        accounting.rely(address(hubHelpers));
        shareClassManager.rely(address(hubHelpers));

        // Rely others on hub
        hub.rely(address(messageDispatcher));
        hubHelpers.rely(address(hub));

        // shareClassManager.rely(address(this));

        // set dependencies
        hub.file("sender", address(messageDispatcher));
        hub.file("poolEscrowFactory", address(poolEscrowFactory));
        hubHelpers.file("hub", address(hub));

        messageDispatcher.file("hub", address(hub));
        messageDispatcher.file("spoke", address(spoke));
        messageDispatcher.file("balanceSheet", address(balanceSheet));
        messageDispatcher.file("requestManager", address(requestManager));
    }

    /// === MODIFIERS === ///
    /// Prank admin and actor

    modifier asAdmin() {
        vm.prank(address(this));
        _;
    }

    modifier asActor() {
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
        if (randomIndex == 0) {
            // the first share class is never assigned
            randomIndex = 1;
        }

        ShareClassId scId = shareClassManager.previewShareClassId(poolId, randomIndex);
        return scId;
    }

    function _getRandomAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 accountEntropy)
        internal
        view
        returns (AccountId)
    {
        uint8 accountType = accountEntropy % 6;
        return holdings.accountId(poolId, scId, assetId, accountType);
    }

    function _getRandomAssetId(uint128 assetEntropy) internal view returns (AssetId) {
        uint256 randomIndex = assetEntropy % createdAssetIds.length;
        return createdAssetIds[randomIndex];
    }

    /// @dev performs the same check as SCM::_updateQueued
    function _canMutate(uint32 lastUpdate, uint128 pending, uint128 latestApproval) internal pure returns (bool) {
        return lastUpdate > latestApproval || pending == 0 || latestApproval == 0;
    }
}
