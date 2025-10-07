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
import {Root} from "src/admin/Root.sol";
import {BalanceSheet} from "src/core/spoke/BalanceSheet.sol";
import {AsyncVaultFactory} from "src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "src/vaults/factories/SyncDepositVaultFactory.sol";
import {RefundEscrowFactory} from "src/vaults/factories/RefundEscrowFactory.sol";
import {TokenFactory} from "src/core/spoke/factories/TokenFactory.sol";
import {PoolEscrowFactory} from "src/core/spoke/factories/PoolEscrowFactory.sol";
import {SyncManager} from "src/vaults/SyncManager.sol";
import {ShareToken} from "src/core/spoke/ShareToken.sol";
import {Spoke} from "src/core/spoke/Spoke.sol";
import {VaultRegistry} from "src/core/spoke/VaultRegistry.sol";

// Hub
import {Accounting} from "src/core/hub/Accounting.sol";
import {HubRegistry} from "src/core/hub/HubRegistry.sol";
import {Gateway} from "src/core/Gateway.sol";
import {Holdings} from "src/core/hub/Holdings.sol";
import {Hub} from "src/core/hub/Hub.sol";
import {ShareClassManager} from "src/core/hub/ShareClassManager.sol";
import {BatchRequestManagerHarness} from "test/integration/recon-end-to-end/mocks/BatchRequestManagerHarness.sol";
import {IdentityValuation} from "src/valuations/IdentityValuation.sol";
import {MessageProcessor} from "src/core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "src/core/messaging/MessageDispatcher.sol";
import {IMessageDispatcher} from "src/core/messaging/interfaces/IMessageDispatcher.sol";
import {TokenRecoverer} from "src/admin/TokenRecoverer.sol";
import {MockAdapter} from "test/core/mocks/MockAdapter.sol";
import {AccountId} from "src/core/types/AccountId.sol";
import {AssetId} from "src/core/types/AssetId.sol";
import {HubHandler} from "src/core/hub/HubHandler.sol";
import {ShareClassId} from "src/core/types/ShareClassId.sol";

// Interfaces
import {IHubRegistry} from "src/core/hub/interfaces/IHubRegistry.sol";
import {IHub} from "src/core/hub/interfaces/IHub.sol";
import {IAccounting} from "src/core/hub/interfaces/IAccounting.sol";
import {IHoldings} from "src/core/hub/interfaces/IHoldings.sol";
import {IHubMessageSender} from "src/core/interfaces/IGatewaySenders.sol";
import {IShareClassManager} from "src/core/hub/interfaces/IShareClassManager.sol";
import {IBatchRequestManager} from "src/vaults/interfaces/IBatchRequestManager.sol";
import {IHubRequestManager} from "src/core/hub/interfaces/IHubRequestManager.sol";
import {IGateway} from "src/core/interfaces/IGateway.sol";
import {IMessageHandler} from "src/core/interfaces/IMessageHandler.sol";
import {IERC6909Decimals} from "src/misc/interfaces/IERC6909.sol";
import {IVaultFactory} from "src/core/spoke/factories/interfaces/IVaultFactory.sol";
import {IHubHandler} from "src/core/hub/interfaces/IHubHandler.sol";
import {IMultiAdapter} from "src/core/interfaces/IMultiAdapter.sol";

// Common
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {ERC20} from "src/misc/ERC20.sol";
import {IRoot} from "src/admin/interfaces/IRoot.sol";
import {PoolId} from "src/core/types/PoolId.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {MockValuation} from "test/core/mocks/MockValuation.sol";

// Test Utils
import {SharedStorage} from "test/integration/recon-end-to-end/helpers/SharedStorage.sol";
import {MockGateway} from "test/integration/recon-end-to-end/mocks/MockGateway.sol";
import {MockAccountValue} from "test/integration/recon-end-to-end/mocks/MockAccountValue.sol";
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
    RefundEscrowFactory refundEscrowFactory;

    AsyncRequestManager asyncRequestManager;
    SyncManager syncManager;
    Spoke spoke;
    VaultRegistry vaultRegistry;
    FullRestrictions fullRestrictions;
    IRoot root;
    BalanceSheet balanceSheet;
    Escrow globalEscrow;

    // Mocks
    MessageDispatcher messageDispatcher;
    TokenRecoverer tokenRecoverer;
    MockGateway gateway;

    // Clamping
    // bytes16 scId;
    // uint64 poolId;
    // uint128 assetId;
    uint128 currencyId;

    // CROSS CHAIN
    uint16 CENTRIFUGE_CHAIN_ID = 1;
    uint256 REQUEST_ID = 0; // LP request ID is always 0
    // bytes32 EVM_ADDRESS = bytes32(uint256(0x1234) << 224); // Unused

    /// === Hub === ///
    Accounting accounting;
    HubRegistry hubRegistry;
    Holdings holdings;
    Hub hub;
    HubHandler hubHandler;
    ShareClassManager shareClassManager;
    BatchRequestManagerHarness batchRequestManager;
    MockValuation transientValuation;
    IdentityValuation identityValuation;

    MockAdapter mockAdapter;
    MockAccountValue mockAccountValue;

    bytes[] internal queuedCalls; // used for storing calls to PoolRouter to be executed in a single transaction
    AccountId[] internal createdAccountIds;
    AssetId[] internal createdAssetIds;
    D18 internal INITIAL_PRICE = d18(1e18); // set the initial price that gets used when creating an asset via a pool's

    // shortcut to avoid stack too deep errors
    uint32 internal MAX_CLAIMS = 20;
    uint32 internal ASSET_ACCOUNT = 1;
    uint32 internal EQUITY_ACCOUNT = 2;
    uint32 internal LOSS_ACCOUNT = 3;
    uint32 internal GAIN_ACCOUNT = 4;
    uint32 internal EXPENSE_ACCOUNT = 5;
    uint32 internal LIABILITY_ACCOUNT = 6;
    uint64 internal POOL_ID_COUNTER = 1;

    // Pool tracking for property iteration
    // NOTE: removed because all tracking now handled by Recon managers
    // PoolId[] public activePools; // Replaced by ReconPoolManager
    // mapping(PoolId => ShareClassId[]) public activeShareClasses; // Replaced by ReconPoolManager
    // AssetId[] public trackedAssets; // Replaced by ReconAssetIdManager

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
        require(address(_getVault()) != address(0));
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

        balanceSheet = new BalanceSheet(root, address(this));
        fullRestrictions = new FullRestrictions(
            address(root),
            address(spoke),
            address(balanceSheet),
            address(globalEscrow),
            address(spoke),
            address(this)
        );
        refundEscrowFactory = new RefundEscrowFactory(address(this));
        asyncRequestManager = new AsyncRequestManager(
            globalEscrow,
            refundEscrowFactory,
            address(this)
        );
        syncManager = new SyncManager(address(this));
        asyncVaultFactory = new AsyncVaultFactory(
            address(this),
            asyncRequestManager,
            address(this)
        );
        syncVaultFactory = new SyncDepositVaultFactory(
            address(root),
            syncManager,
            asyncRequestManager,
            address(this)
        );
        tokenFactory = new TokenFactory(address(this), address(this));
        poolEscrowFactory = new PoolEscrowFactory(address(root), address(this));
        vaultRegistry = new VaultRegistry(address(this));
        spoke = new Spoke(tokenFactory, address(this));

        tokenRecoverer = new TokenRecoverer(
            IRoot(address(root)),
            address(this)
        );
        Root(address(root)).rely(address(tokenRecoverer));
        tokenRecoverer.rely(address(root));
        tokenRecoverer.rely(address(messageDispatcher));

        messageDispatcher = new MessageDispatcher(
            CENTRIFUGE_CHAIN_ID, // localCentrifugeId = 1 for same-chain testing
            IRoot(address(root)), // scheduleAuth
            IGateway(address(gateway)),
            address(this)
        );

        // set dependencies
        asyncRequestManager.file("spoke", address(spoke));
        asyncRequestManager.file("balanceSheet", address(balanceSheet));
        asyncRequestManager.file("vaultRegistry", address(vaultRegistry));
        syncManager.file("spoke", address(spoke));
        syncManager.file("balanceSheet", address(balanceSheet));
        syncManager.file("vaultRegistry", address(vaultRegistry));
        vaultRegistry.file("spoke", address(spoke));
        spoke.file("gateway", address(gateway));
        spoke.file("sender", address(messageDispatcher));
        spoke.file("tokenFactory", address(tokenFactory));
        spoke.file("poolEscrowFactory", address(poolEscrowFactory));
        balanceSheet.file("spoke", address(spoke));
        balanceSheet.file("sender", address(messageDispatcher));
        balanceSheet.file("poolEscrowProvider", address(poolEscrowFactory));

        balanceSheet.file("gateway", address(gateway));
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
        transientValuation = new MockValuation(hubRegistry);
        identityValuation = new IdentityValuation(hubRegistry);
        mockAdapter = new MockAdapter(
            CENTRIFUGE_CHAIN_ID,
            IMessageHandler(address(gateway))
        );
        mockAccountValue = new MockAccountValue();

        // Core Hub Contracts
        accounting = new Accounting(address(this));
        holdings = new Holdings(
            IHubRegistry(address(hubRegistry)),
            address(this)
        );
        shareClassManager = new ShareClassManager(
            IHubRegistry(address(hubRegistry)),
            address(this)
        );
        batchRequestManager = new BatchRequestManagerHarness(
            IHubRegistry(address(hubRegistry)),
            address(this)
        );
        hub = new Hub(
            IGateway(address(gateway)),
            IHoldings(address(holdings)),
            IAccounting(address(accounting)),
            IHubRegistry(address(hubRegistry)),
            IMultiAdapter(address(mockAdapter)),
            IShareClassManager(address(shareClassManager)),
            address(this)
        );

        // Initialize HubHandler with correct parameters (hub, holdings, hubRegistry, shareClassManager, deployer)
        hubHandler = new HubHandler(
            IHub(address(hub)),
            IHoldings(address(holdings)),
            IHubRegistry(address(hubRegistry)),
            IShareClassManager(address(shareClassManager)),
            address(this)
        );

        // set permissions for calling privileged functions
        hubRegistry.rely(address(hub));
        holdings.rely(address(hub));
        accounting.rely(address(hub));
        shareClassManager.rely(address(hub));
        batchRequestManager.rely(address(hub));
        batchRequestManager.rely(address(hubHandler));
        batchRequestManager.rely(address(messageDispatcher));
        batchRequestManager.file("hub", address(hub));
        poolEscrowFactory.rely(address(hub));

        // Add missing Root permissions (matching HubDeployer)
        hubRegistry.rely(address(root));
        holdings.rely(address(root));
        accounting.rely(address(root));
        shareClassManager.rely(address(root));
        hub.rely(address(root));
        hubHandler.rely(address(root));

        accounting.rely(address(hubHandler));
        shareClassManager.rely(address(hubHandler));
        hubRegistry.rely(address(hubHandler));
        holdings.rely(address(hubHandler));
        hub.rely(address(hubHandler));
        // Hub needs permission to call HubHelpers functions
        hubHandler.rely(address(hub));

        // Add missing HubHelpers permissions (matching HubDeployer)
        hubHandler.rely(address(messageDispatcher));

        hub.rely(address(messageDispatcher));

        // Add missing Gateway permission for Hub (matching HubDeployer)
        gateway.rely(address(hub));

        // MessageDispatcher needs auth permissions to call protected functions
        spoke.rely(address(messageDispatcher));
        balanceSheet.rely(address(messageDispatcher));

        // Spoke, balanceSheet, and hub need permission to call MessageDispatcher
        messageDispatcher.rely(address(spoke));
        messageDispatcher.rely(address(balanceSheet));
        messageDispatcher.rely(address(hub));

        // Add missing MessageDispatcher permissions (matching HubDeployer)
        messageDispatcher.rely(address(root));
        messageDispatcher.rely(address(hubHandler));

        // set dependencies
        hub.file("sender", address(messageDispatcher));

        messageDispatcher.file("hubHandler", address(hubHandler));
        messageDispatcher.file("spoke", address(spoke));
        messageDispatcher.file("balanceSheet", address(balanceSheet));

        // Add missing HubHelpers file configuration (matching HubDeployer)
        hubHandler.file("hub", address(hub));
    }

    /// === Helper Functions === ///

    /// @dev Returns a random actor from the list of actors
    /// @dev This is useful for cases where we want to have caller and recipient be different actors
    /// @param entropy The determines which actor is chosen from the array
    function _getRandomActor(
        uint256 entropy
    ) internal view returns (address randomActor) {
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
        asyncVaultFactory.rely(address(vaultRegistry));
        syncVaultFactory.rely(address(spoke));
        syncVaultFactory.rely(address(vaultRegistry));
        tokenFactory.rely(address(spoke));
        asyncRequestManager.rely(address(spoke));
        syncManager.rely(address(spoke));
        fullRestrictions.rely(address(spoke));
        poolEscrowFactory.rely(address(spoke));
        gateway.rely(address(spoke));
        vaultRegistry.rely(address(spoke));

        // Rely async requests manager
        globalEscrow.rely(address(asyncRequestManager));
        asyncRequestManager.rely(address(asyncVaultFactory));
        asyncRequestManager.rely(address(syncVaultFactory));
        asyncRequestManager.rely(address(messageDispatcher));
        asyncRequestManager.rely(address(syncManager));

        // Rely VaultRegistry
        vaultRegistry.rely(address(asyncVaultFactory));
        vaultRegistry.rely(address(syncVaultFactory));
        vaultRegistry.rely(address(messageDispatcher));

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
        balanceSheet.rely(address(gateway));
        // Rely global escrow
        globalEscrow.rely(address(asyncRequestManager));
        globalEscrow.rely(address(syncManager));
        globalEscrow.rely(address(spoke));
        globalEscrow.rely(address(balanceSheet));

        // Rely Root (from all deployers)
        spoke.rely(address(root));
        spoke.rely(address(vaultRegistry));
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
        vaultRegistry.rely(address(root));

        // Rely gateway
        spoke.rely(address(gateway));

        // Add missing Gateway permissions (matching CommonDeployer)
        gateway.rely(address(messageDispatcher));

        // Rely messageDispatcher - these contracts rely on messageDispatcher, not the other way around
        spoke.rely(address(messageDispatcher));
        balanceSheet.rely(address(messageDispatcher));
    }

    // ===============================
    // HELPER FUNCTIONS FOR SHARE QUEUE PROPERTIES
    // ===============================

    /// @notice Capture share queue state before operation
    function _captureShareQueueState(
        PoolId poolId,
        ShareClassId scId
    ) internal {
        bytes32 key = _poolShareKey(poolId, scId);

        (
            uint128 delta,
            bool isPositive,
            uint32 queuedAssetCounter,
            uint64 nonce
        ) = balanceSheet.queuedShares(poolId, scId);

        before_shareQueueDelta[key] = delta;
        before_shareQueueIsPositive[key] = isPositive;
        before_nonce[key] = nonce;
    }

    /// @notice Generate consistent key for pool-share class combination
    function _poolShareKey(
        PoolId poolId,
        ShareClassId scId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, scId));
    }

    /// @notice Track pools and share classes for property iteration
    // function _trackPoolAndShareClass(
    //     PoolId poolId,
    //     ShareClassId scId
    // ) internal {
    //     // Check if pool is already tracked using ReconPoolManager
    //     PoolId[] memory pools = _getPools();
    //     bool poolExists = false;
    //     for (uint256 i = 0; i < pools.length; i++) {
    //         if (PoolId.unwrap(pools[i]) == PoolId.unwrap(poolId)) {
    //             poolExists = true;
    //             break;
    //         }
    //     }
    //     if (!poolExists) {
    //         _addPool(PoolId.unwrap(poolId));
    //     }

    //     // Check if share class is already tracked for this pool
    //     if (!_poolHasShareClass(poolId, scId)) {
    //         _addShareClassToPool(poolId, scId);
    //     }
    // }

    /// @notice Track asset for property iteration
    function _trackAsset(AssetId assetId) internal {
        // Check if asset is already tracked using ReconAssetIdManager
        AssetId[] memory assets = _getAssetIds();
        for (uint256 i = 0; i < assets.length; i++) {
            if (AssetId.unwrap(assets[i]) == AssetId.unwrap(assetId)) {
                return; // Already tracked
            }
        }
        _addAssetId(AssetId.unwrap(assetId));
    }

    // Authorization helper functions

    /// @notice Track authorization for a caller performing privileged operation
    function _trackAuthorization(address caller, PoolId poolId) internal {
        bytes32 key = keccak256(abi.encode(poolId));

        // Check actual authorization
        bool isWard = balanceSheet.wards(caller) == 1;
        bool isManager = balanceSheet.manager(poolId, caller);

        // Update ghost tracking
        if (isWard) {
            ghost_authorizationLevel[caller] = AuthLevel.WARD;
        } else if (isManager) {
            ghost_authorizationLevel[caller] = AuthLevel.MANAGER;
        } else {
            ghost_authorizationLevel[caller] = AuthLevel.NONE;
            ghost_unauthorizedAttempts[key]++;
        }

        if (isWard || isManager) {
            ghost_privilegedOperationCount[key]++;
            ghost_lastAuthorizedCaller[key] = caller;
        }
    }

    /// @notice Check and record authorization level changes
    function _checkAndRecordAuthChange(address user) internal {
        AuthLevel oldLevel = ghost_authorizationLevel[user];
        AuthLevel newLevel = AuthLevel.NONE;

        // Check all pools for manager permissions - simplified for testing
        // In a full implementation, this would check all tracked pools
        if (balanceSheet.wards(user) == 1) {
            newLevel = AuthLevel.WARD;
        } else {
            // Check if user is manager for any tracked pool
            PoolId[] memory pools = _getPools();
            for (uint256 i = 0; i < pools.length; i++) {
                if (balanceSheet.manager(pools[i], user)) {
                    newLevel = AuthLevel.MANAGER;
                    break;
                }
            }
        }

        if (oldLevel != newLevel) {
            ghost_authorizationChanges[user]++;
            ghost_authorizationLevel[user] = newLevel;
        }
    }

    // Endorsement helper functions

    /// @dev Check if an address is an endorsed contract
    function _isEndorsedContract(address addr) internal view returns (bool) {
        // Check if address is endorsed by root
        return root.endorsed(addr);
    }

    /// @dev Track transfer attempts for endorsement validation
    function _trackEndorsedTransfer(
        address from,
        address to,
        PoolId poolId,
        ShareClassId scId
    ) internal {
        bytes32 key = keccak256(abi.encode(poolId, scId));

        // Track transfer details
        ghost_lastTransferFrom[key] = from;

        // Check if from is endorsed
        if (_isEndorsedContract(from)) {
            ghost_endorsedTransferAttempts[key]++;
            ghost_isEndorsedContract[from] = true;
        }

        // Track system contracts as implicitly endorsed
        if (
            from == address(balanceSheet) ||
            from == address(spoke) ||
            from == address(hub)
        ) {
            ghost_isEndorsedContract[from] = true;
            ghost_endorsedTransferAttempts[key]++;
        }
    }
}
