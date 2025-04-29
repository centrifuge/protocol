// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import { vm } from "@chimera/Hevm.sol";
import {ActorManager} from "@recon/ActorManager.sol";
import {AssetManager} from "@recon/AssetManager.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {Utils} from "@recon/Utils.sol";
import {console2} from "forge-std/console2.sol";

// Vaults
import {Escrow} from "src/vaults/Escrow.sol";
import {AsyncRequestManager} from "src/vaults/AsyncRequestManager.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {Root} from "src/common/Root.sol";
import {BalanceSheet} from "src/vaults/BalanceSheet.sol";
import {AsyncVaultFactory} from "src/vaults/factories/AsyncVaultFactory.sol";
import {TokenFactory} from "src/vaults/factories/TokenFactory.sol";
import {PoolEscrowFactory} from "src/vaults/factories/PoolEscrowFactory.sol";
import {SyncRequestManager} from "src/vaults/SyncRequestManager.sol";
import {ShareToken} from "src/vaults/token/ShareToken.sol";
import {Escrow} from "src/vaults/Escrow.sol";

// Hub
import {Accounting} from "src/hub/Accounting.sol";
import {HubRegistry} from "src/hub/HubRegistry.sol";
import {Gateway} from "src/common/Gateway.sol";
import {Holdings} from "src/hub/Holdings.sol";
import {HubRegistry} from "src/hub/HubRegistry.sol";
import {Hub} from "src/hub/Hub.sol";
import {ShareClassManager} from "src/hub/ShareClassManager.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {TransientValuation} from "test/misc/mocks/TransientValuation.sol";
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
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IAccounting} from "src/hub/interfaces/IAccounting.sol";
import {IERC6909Decimals} from "src/misc/interfaces/IERC6909.sol";
import {IVaultFactory} from "src/vaults/interfaces/factories/IVaultFactory.sol";

// Common
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {ERC20} from "src/misc/ERC20.sol";
import {Root} from "src/common/Root.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {D18, d18} from "src/misc/types/D18.sol";

// Test Utils
import {SharedStorage} from "./helpers/SharedStorage.sol";
import {MockMessageProcessor} from "./mocks/MockMessageProcessor.sol";
import {MockMessageDispatcher} from "./mocks/MockMessageDispatcher.sol";
import {ShareClassManagerWrapper} from "test/hub/fuzzing/recon-hub/utils/ShareClassManagerWrapper.sol";
import {MockGateway} from "./mocks/MockGateway.sol";
import {MockAccountValue} from "test/hub/fuzzing/recon-hub/mocks/MockAccountValue.sol";


abstract contract Setup is BaseSetup, SharedStorage, ActorManager, AssetManager, Utils {

    /// === Vaults === ///
    AsyncVaultFactory vaultFactory;
    TokenFactory tokenFactory;
    PoolEscrowFactory poolEscrowFactory;

    AsyncRequestManager asyncRequestManager;
    SyncRequestManager syncRequestManager;
    PoolManager poolManager;
    AsyncVault vault;
    ShareToken token;
    FullRestrictions fullRestrictions;
    IRoot root;
    BalanceSheet balanceSheet;
    Escrow globalEscrow;

    // Mocks
    MockMessageDispatcher messageDispatcher;
    MockGateway gateway;

    // Clamping
    bytes16 scId;
    uint64 poolId;
    uint128 assetId;
    uint128 currencyId;

    // CROSS CHAIN
    uint16 CENTIFUGE_CHAIN_ID = 1;
    uint256 REQUEST_ID = 0;  // LP request ID is always 0
    bytes32 EVM_ADDRESS = bytes32(uint256(0x1234) << 224);

    /// === Hub === ///
    Accounting accounting;
    HubRegistry hubRegistry;
    Holdings holdings;
    Hub hub;
    ShareClassManagerWrapper shareClassManager;
    TransientValuation transientValuation;
    IdentityValuation identityValuation;

    MockAdapter mockAdapter;
    MockAccountValue mockAccountValue;

    bytes[] internal queuedCalls; // used for storing calls to PoolRouter to be executed in a single transaction
    PoolId[] internal createdPools;
    AccountId[] internal createdAccountIds;
    AssetId[] internal createdAssetIds;
    D18 internal INITIAL_PRICE = d18(1e18); // set the initial price that gets used when creating an asset via a pool's shortcut to avoid stack too deep errors
    bool internal IS_LIABILITY = true; /// @dev see toggle_IsLiability
    bool internal IS_INCREASE = true; /// @dev see toggle_IsIncrease
    bool internal IS_DEBIT_NORMAL = true;
    uint32 internal MAX_CLAIMS = type(uint32).max;
    AccountId internal ACCOUNT_TO_UPDATE = AccountId.wrap(0); /// @dev see toggle_AccountToUpdate
    uint32 internal ASSET_ACCOUNT = 1;
    uint32 internal EQUITY_ACCOUNT = 2;
    uint32 internal LOSS_ACCOUNT = 3;
    uint32 internal GAIN_ACCOUNT = 4;
    uint64 internal POOL_ID_COUNTER = 1;

    /// === GHOST === ///
    mapping (address => uint256) requestDeposited;
    mapping (address => uint256) depositProcessed;
    mapping (address => uint256) cancelledDeposits;

    mapping (address => uint256) requestRedeeemed;
    mapping (address => uint256) redemptionsProcessed;
    mapping (address => uint256) cancelledRedemptions;

    uint256 approvedDeposits;
    uint256 approvedRedemptions;

    modifier asAdmin {
        vm.prank(address(this));
        _;
    }

    modifier asActor {
        vm.prank(address(_getActor()));
        _;
    }

    modifier tokenIsSet() {
        require(address(token) != address(0));
        _;
    }

    modifier assetIsSet() {
        require(_getAsset() != address(0));
        _;
    }

    modifier statelessTest() {
        _;
        revert("statelessTest");
    }

    function setup() internal virtual override {
        // add two actors in addition to the default admin (address(this))
        _addActor(address(0x10000));
        _addActor(address(0x20000));

        setupVaults();
        setupHub();
    }

    function setupVaults() internal {
        // Dependencies
        root = new Root(48 hours, address(this));
        gateway = new MockGateway();
        globalEscrow = new Escrow(address(this));
        root.endorse(address(globalEscrow));

        fullRestrictions = new FullRestrictions(address(root), address(this));
        balanceSheet = new BalanceSheet(root, address(this));
        asyncRequestManager = new AsyncRequestManager(globalEscrow, address(root), address(this));
        syncRequestManager = new SyncRequestManager(globalEscrow, address(root), address(this));
        vaultFactory = new AsyncVaultFactory(address(this), asyncRequestManager, address(this));
        tokenFactory = new TokenFactory(address(this), address(this));
        poolEscrowFactory = new PoolEscrowFactory(address(root), address(this));
        
        IVaultFactory[] memory vaultFactories = new IVaultFactory[](1);
        vaultFactories[0] = vaultFactory;
        poolManager = new PoolManager(tokenFactory, vaultFactories, address(this));
        messageDispatcher = new MockMessageDispatcher(); 

        // set dependencies
        asyncRequestManager.file("sender", address(messageDispatcher));
        asyncRequestManager.file("poolManager", address(poolManager));
        asyncRequestManager.file("balanceSheet", address(balanceSheet));    
        asyncRequestManager.file("sharePriceProvider", address(syncRequestManager));
        syncRequestManager.file("poolManager", address(poolManager));
        syncRequestManager.file("balanceSheet", address(balanceSheet));
        poolManager.file("sender", address(messageDispatcher));
        poolManager.file("tokenFactory", address(tokenFactory));
        poolManager.file("gateway", address(gateway));
        poolManager.file("balanceSheet", address(balanceSheet));
        poolManager.file("poolEscrowFactory", address(poolEscrowFactory));
        balanceSheet.file("gateway", address(gateway));
        balanceSheet.file("poolManager", address(poolManager));
        balanceSheet.file("sender", address(messageDispatcher));
        balanceSheet.file("sharePriceProvider", address(syncRequestManager));

        // authorize contracts
        asyncRequestManager.rely(address(poolManager));
        asyncRequestManager.rely(address(vaultFactory));
        asyncRequestManager.rely(address(messageDispatcher));
        poolManager.rely(address(messageDispatcher));
        fullRestrictions.rely(address(poolManager));
        balanceSheet.rely(address(asyncRequestManager));
        balanceSheet.rely(address(syncRequestManager));
        balanceSheet.rely(address(messageDispatcher));
        globalEscrow.rely(address(asyncRequestManager));
        globalEscrow.rely(address(syncRequestManager));
        globalEscrow.rely(address(poolManager));
        globalEscrow.rely(address(balanceSheet));
        // Permissions on factories
        vaultFactory.rely(address(poolManager));
        tokenFactory.rely(address(poolManager));
    }

    function setupHub() internal {
        hubRegistry = new HubRegistry(address(this)); 
        transientValuation = new TransientValuation(IERC6909Decimals(address(this)));
        identityValuation = new IdentityValuation(IHubRegistry(address(hubRegistry)), address(this));
        mockAdapter = new MockAdapter(CENTIFUGE_CHAIN_ID, IMessageHandler(address(gateway)));
        mockAccountValue = new MockAccountValue();

        // Core Hub Contracts
        accounting = new Accounting(address(this)); 
        holdings = new Holdings(IHubRegistry(address(hubRegistry)), address(this));
        shareClassManager = new ShareClassManagerWrapper(IHubRegistry(address(hubRegistry)), address(this));
        hub = new Hub(
            IShareClassManager(address(shareClassManager)), 
            IHubRegistry(address(hubRegistry)), 
            IAccounting(address(accounting)), 
            IHoldings(address(holdings)), 
            IGateway(address(gateway)), 
            address(this)
        );

        // set permissions for calling privileged functions
        hubRegistry.rely(address(hub));
        accounting.rely(address(hub));
        holdings.rely(address(hub));
        shareClassManager.rely(address(hub));
        hub.rely(address(hub));
        hub.rely(address(messageDispatcher));
        shareClassManager.rely(address(this));

        // set dependencies
        hub.file("sender", address(messageDispatcher));
        messageDispatcher.file("hub", address(hub)); 
        messageDispatcher.file("poolManager", address(poolManager));
        messageDispatcher.file("investmentManager", address(asyncRequestManager));
        messageDispatcher.file("balanceSheet", address(balanceSheet));
    }


    /// === Helper Functions === ///

    /// @dev Returns a random actor from the list of actors
    /// @dev This is useful for cases where we want to have caller and recipient be different actors
    /// @param entropy The determines which actor is chosen from the array
    function _getRandomActor(uint256 entropy) internal view returns (address randomActor) {
        address[] memory actorsArray = _getActors();
        randomActor = actorsArray[entropy % actorsArray.length];
    }

    // MOCK++
    fallback() external payable {
        // Basically we will receive `root.rely, etc..`
    }

    receive() external payable {}
}
