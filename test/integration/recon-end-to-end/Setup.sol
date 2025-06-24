// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import {vm} from "@chimera/Hevm.sol";
import {ActorManager} from "@recon/ActorManager.sol";
import {AssetManager} from "@recon/AssetManager.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {Utils} from "@recon/Utils.sol";
import {console2} from "forge-std/console2.sol";

// Vaults
import {Escrow} from "src/misc/Escrow.sol";
import {AsyncRequestManager} from "src/vaults/AsyncRequestManager.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {Root} from "src/common/Root.sol";
import {BalanceSheet} from "src/spoke/BalanceSheet.sol";
import {AsyncVaultFactory} from "src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "src/vaults/factories/SyncDepositVaultFactory.sol";
import {TokenFactory} from "src/spoke/factories/TokenFactory.sol";
import {PoolEscrowFactory} from "src/common/factories/PoolEscrowFactory.sol";
import {SyncManager} from "src/vaults/SyncManager.sol";
import {ShareToken} from "src/spoke/ShareToken.sol";
import {Spoke} from "src/spoke/Spoke.sol";

// Hub
import {Accounting} from "src/hub/Accounting.sol";
import {HubRegistry} from "src/hub/HubRegistry.sol";
import {Gateway} from "src/common/Gateway.sol";
import {Holdings} from "src/hub/Holdings.sol";
import {Hub} from "src/hub/Hub.sol";
import {ShareClassManager} from "src/hub/ShareClassManager.sol";
import {IdentityValuation} from "src/misc/IdentityValuation.sol";
import {MessageProcessor} from "src/common/MessageProcessor.sol";
import {Root} from "src/common/Root.sol";
import {MockAdapter} from "test/common/mocks/MockAdapter.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {HubHelpers} from "src/hub/HubHelpers.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

// Interfaces
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {IAccounting} from "src/hub/interfaces/IAccounting.sol";
import {IHoldings} from "src/hub/interfaces/IHoldings.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";
import {IHubMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IERC6909Decimals} from "src/misc/interfaces/IERC6909.sol";
import {IVaultFactory} from "src/spoke/factories/interfaces/IVaultFactory.sol";
import {IHubHelpers} from "src/hub/interfaces/IHubHelpers.sol";

// Common
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {ERC20} from "src/misc/ERC20.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {MockValuation} from "test/common/mocks/MockValuation.sol";

// Test Utils
import {SharedStorage} from "test/integration/recon-end-to-end/helpers/SharedStorage.sol";
import {MockMessageProcessor} from "test/integration/recon-end-to-end/mocks/MockMessageProcessor.sol";
import {MockMessageDispatcher} from "test/integration/recon-end-to-end/mocks/MockMessageDispatcher.sol";
import {MockGateway} from "test/integration/recon-end-to-end/mocks/MockGateway.sol";
import {MockAccountValue} from "test/hub/fuzzing/recon-hub/mocks/MockAccountValue.sol";
import {ReconPoolManager} from "test/integration/recon-end-to-end/managers/ReconPoolManager.sol";
import {ReconShareClassManager} from "test/integration/recon-end-to-end/managers/ReconShareClassManager.sol";
import {ReconAssetIdManager} from "test/integration/recon-end-to-end/managers/ReconAssetIdManager.sol";
import {ReconVaultManager} from "test/integration/recon-end-to-end/managers/ReconVaultManager.sol";
import {ReconShareManager} from "test/integration/recon-end-to-end/managers/ReconShareManager.sol";

abstract contract Setup is
    BaseSetup,
    SharedStorage,
    ActorManager,
    AssetManager,
    ReconPoolManager,
    ReconShareClassManager,
    ReconAssetIdManager,
    ReconVaultManager,
    ReconShareManager,
    Utils
{
    /// === Vaults === ///
    AsyncVaultFactory asyncVaultFactory;
    SyncDepositVaultFactory syncVaultFactory;
    TokenFactory tokenFactory;
    PoolEscrowFactory poolEscrowFactory;

    AsyncRequestManager asyncRequestManager;
    SyncManager syncManager;
    Spoke spoke;
    FullRestrictions fullRestrictions;
    IRoot root;
    BalanceSheet balanceSheet;
    Escrow globalEscrow;

    // Mocks
    MockMessageDispatcher messageDispatcher;
    MockGateway gateway;

    // Clamping
    // bytes16 scId;
    // uint64 poolId;
    // uint128 assetId;
    uint128 currencyId;

    // CROSS CHAIN
    uint16 CENTRIFUGE_CHAIN_ID = 1;
    uint256 REQUEST_ID = 0; // LP request ID is always 0
    bytes32 EVM_ADDRESS = bytes32(uint256(0x1234) << 224);

    /// === Hub === ///
    Accounting accounting;
    HubRegistry hubRegistry;
    Holdings holdings;
    Hub hub;
    HubHelpers hubHelpers;
    ShareClassManager shareClassManager;
    MockValuation transientValuation;
    IdentityValuation identityValuation;

    MockAdapter mockAdapter;
    MockAccountValue mockAccountValue;

    bytes[] internal queuedCalls; // used for storing calls to PoolRouter to be executed in a single transaction
    AccountId[] internal createdAccountIds;
    AssetId[] internal createdAssetIds;
    D18 internal INITIAL_PRICE = d18(1e18); // set the initial price that gets used when creating an asset via a pool's
        // shortcut to avoid stack too deep errors
    bool internal IS_LIABILITY = true;
    /// @dev see toggle_IsLiability
    bool internal IS_INCREASE = true;
    /// @dev see toggle_IsIncrease
    bool internal IS_DEBIT_NORMAL = true;
    uint32 internal MAX_CLAIMS = 20;
    AccountId internal ACCOUNT_TO_UPDATE = AccountId.wrap(0);
    /// @dev see toggle_AccountToUpdate
    uint32 internal ASSET_ACCOUNT = 1;
    uint32 internal EQUITY_ACCOUNT = 2;
    uint32 internal LOSS_ACCOUNT = 3;
    uint32 internal GAIN_ACCOUNT = 4;
    uint64 internal POOL_ID_COUNTER = 1;

    /// === GHOST === ///
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(address user => uint256))) requestDeposited;
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(address user => uint256))) depositProcessed;
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(address user => uint256))) cancelledDeposits;

    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(address user => uint256))) requestRedeemed;
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(address user => uint256))) requestRedeemedAssets;
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(address user => uint256))) redemptionsProcessed;
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(address user => uint256))) cancelledRedemptions;

    mapping(ShareClassId scId => mapping(AssetId assetId => uint256)) approvedDeposits;
    mapping(ShareClassId scId => mapping(AssetId assetId => uint256)) approvedRedemptions;

    mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => uint256))) issuedHubShares;
    mapping(PoolId poolId => mapping(ShareClassId scId => uint256)) issuedBalanceSheetShares;
    mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => uint256))) revokedHubShares;
    mapping(PoolId poolId => mapping(ShareClassId scId => uint256)) revokedBalanceSheetShares;

    int256 maxDepositGreater;
    int256 maxDepositLess;
    int256 maxRedeemGreater;
    int256 maxRedeemLess;

    modifier asAdmin() {
        vm.prank(address(this));
        _;
    }

    modifier asActor() {
        vm.prank(address(_getActor()));
        _;
    }

    modifier tokenIsSet() {
        require(_getShareToken() != address(0));
        _;
    }

    modifier assetIsSet() {
        require(_getAsset() != address(0));
        _;
    }

    modifier vaultIsSet() {
        require(_getVault() != address(0));
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
        asyncRequestManager = new AsyncRequestManager(globalEscrow, address(this));
        syncManager = new SyncManager(address(this));
        asyncVaultFactory = new AsyncVaultFactory(address(this), asyncRequestManager, address(this));
        syncVaultFactory = new SyncDepositVaultFactory(address(root), syncManager, asyncRequestManager, address(this));
        tokenFactory = new TokenFactory(address(this), address(this));
        poolEscrowFactory = new PoolEscrowFactory(address(root), address(this));
        spoke = new Spoke(tokenFactory, address(this));
        messageDispatcher = new MockMessageDispatcher();

        // set dependencies
        asyncRequestManager.file("spoke", address(spoke));
        asyncRequestManager.file("balanceSheet", address(balanceSheet));
        syncManager.file("spoke", address(spoke));
        syncManager.file("balanceSheet", address(balanceSheet));
        spoke.file("gateway", address(gateway));
        spoke.file("sender", address(messageDispatcher));
        spoke.file("tokenFactory", address(tokenFactory));
        spoke.file("poolEscrowFactory", address(poolEscrowFactory));
        balanceSheet.file("spoke", address(spoke));
        balanceSheet.file("sender", address(messageDispatcher));
        balanceSheet.file("poolEscrowProvider", address(poolEscrowFactory));
        poolEscrowFactory.file("gateway", address(gateway));
        poolEscrowFactory.file("balanceSheet", address(balanceSheet));
        address[] memory tokenWards = new address[](2);
        tokenWards[0] = address(spoke);
        tokenWards[1] = address(balanceSheet);
        tokenFactory.file("wards", tokenWards);

        // Set up all spoke permissions
        setupSpokePermissions();

        root.endorse(address(asyncRequestManager));
        root.endorse(address(syncManager));
    }

    function setupHub() internal {
        hubRegistry = new HubRegistry(address(this));
        transientValuation = new MockValuation(IERC6909Decimals(address(hubRegistry)));
        identityValuation = new IdentityValuation(IERC6909Decimals(address(hubRegistry)), address(this));
        mockAdapter = new MockAdapter(CENTRIFUGE_CHAIN_ID, IMessageHandler(address(gateway)));
        mockAccountValue = new MockAccountValue();

        // Core Hub Contracts
        accounting = new Accounting(address(this));
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
        hub = new Hub(
            IGateway(address(gateway)),
            IHoldings(address(holdings)),
            IHubHelpers(address(hubHelpers)),
            IAccounting(address(accounting)),
            IHubRegistry(address(hubRegistry)),
            IShareClassManager(address(shareClassManager)),
            address(this)
        );

        // set permissions for calling privileged functions
        hubRegistry.rely(address(hub));
        holdings.rely(address(hub));
        accounting.rely(address(hub));
        shareClassManager.rely(address(hub));
        poolEscrowFactory.rely(address(hub));

        accounting.rely(address(hubHelpers));
        shareClassManager.rely(address(hubHelpers));
        // Hub needs permission to call HubHelpers functions
        hubHelpers.rely(address(hub));

        hub.rely(address(messageDispatcher));

        // shareClassManager.rely(address(this));

        // set dependencies
        hub.file("sender", address(messageDispatcher));
        hub.file("poolEscrowFactory", address(poolEscrowFactory));

        messageDispatcher.file("hub", address(hub));
        messageDispatcher.file("spoke", address(spoke));
        messageDispatcher.file("requestManager", address(asyncRequestManager));
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

    // Note: messageDispatcher is a mock and doesn't have rely function
    function setupSpokePermissions() private {
        // Root endorsements (from CommonDeployer and SpokeDeployer)
        root.endorse(address(balanceSheet));
        root.endorse(address(asyncRequestManager));
        root.endorse(address(globalEscrow));

        // Rely Spoke (from SpokeDeployer)
        asyncVaultFactory.rely(address(spoke));
        syncVaultFactory.rely(address(spoke));
        tokenFactory.rely(address(spoke));
        asyncRequestManager.rely(address(spoke));
        syncManager.rely(address(spoke));
        fullRestrictions.rely(address(spoke));
        poolEscrowFactory.rely(address(spoke));
        gateway.rely(address(spoke));

        // Rely async requests manager
        globalEscrow.rely(address(asyncRequestManager));
        asyncRequestManager.rely(address(asyncVaultFactory));
        asyncRequestManager.rely(address(syncVaultFactory));
        asyncRequestManager.rely(address(messageDispatcher));
        asyncRequestManager.rely(address(syncManager));

        // Rely sync manager
        syncManager.rely(address(spoke));
        syncManager.rely(address(asyncVaultFactory));
        syncManager.rely(address(syncVaultFactory));
        syncManager.rely(address(messageDispatcher));
        syncManager.rely(address(asyncRequestManager));
        syncManager.rely(address(syncVaultFactory));

        // Rely BalanceSheet
        gateway.rely(address(balanceSheet));
        balanceSheet.rely(address(asyncRequestManager));
        balanceSheet.rely(address(syncManager));
        balanceSheet.rely(address(messageDispatcher));

        // Rely global escrow
        globalEscrow.rely(address(asyncRequestManager));
        globalEscrow.rely(address(syncManager));
        globalEscrow.rely(address(spoke));
        globalEscrow.rely(address(balanceSheet));

        // Rely Root (from all deployers)
        spoke.rely(address(root));
        asyncRequestManager.rely(address(root));
        syncManager.rely(address(root));
        balanceSheet.rely(address(root));
        globalEscrow.rely(address(root));
        asyncVaultFactory.rely(address(root));
        syncVaultFactory.rely(address(root));
        tokenFactory.rely(address(root));
        fullRestrictions.rely(address(root));
        gateway.rely(address(root));
        poolEscrowFactory.rely(address(root));

        // Rely gateway
        spoke.rely(address(gateway));

        // Rely messageDispatcher - these contracts rely on messageDispatcher, not the other way around
        spoke.rely(address(messageDispatcher));
        balanceSheet.rely(address(messageDispatcher));
    }
}
