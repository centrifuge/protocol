// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "../../../src/misc/ERC20.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {IERC7575Share, IERC165} from "../../../src/misc/interfaces/IERC7575.sol";

import {Hub} from "../../../src/core/hub/Hub.sol";
import {Spoke} from "../../../src/core/spoke/Spoke.sol";
import {PoolId} from "../../../src/core/types/PoolId.sol";
import {Holdings} from "../../../src/core/hub/Holdings.sol";
import {Accounting} from "../../../src/core/hub/Accounting.sol";
import {Gateway} from "../../../src/core/messaging/Gateway.sol";
import {HubHandler} from "../../../src/core/hub/HubHandler.sol";
import {HubRegistry} from "../../../src/core/hub/HubRegistry.sol";
import {BalanceSheet} from "../../../src/core/spoke/BalanceSheet.sol";
import {GasService} from "../../../src/core/messaging/GasService.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../src/core/types/AssetId.sol";
import {VaultRegistry} from "../../../src/core/spoke/VaultRegistry.sol";
import {MultiAdapter} from "../../../src/core/messaging/MultiAdapter.sol";
import {ShareClassManager} from "../../../src/core/hub/ShareClassManager.sol";
import {MessageProcessor} from "../../../src/core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../../../src/core/messaging/MessageDispatcher.sol";

import {Root} from "../../../src/admin/Root.sol";
import {OpsGuardian} from "../../../src/admin/OpsGuardian.sol";
import {ProtocolGuardian} from "../../../src/admin/ProtocolGuardian.sol";

import {MockSnapshotHook} from "../../hooks/mocks/MockSnapshotHook.sol";

import {FreezeOnly} from "../../../src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "../../../src/hooks/FullRestrictions.sol";
import {RedemptionRestrictions} from "../../../src/hooks/RedemptionRestrictions.sol";
import {UpdateRestrictionMessageLib} from "../../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {OracleValuation} from "../../../src/valuations/OracleValuation.sol";
import {IdentityValuation} from "../../../src/valuations/IdentityValuation.sol";

import {SyncManager} from "../../../src/vaults/SyncManager.sol";
import {VaultRouter} from "../../../src/vaults/VaultRouter.sol";
import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {AsyncRequestManager} from "../../../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../../../src/vaults/BatchRequestManager.sol";

import {FullDeployer} from "../../../script/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {IntegrationConstants} from "../utils/IntegrationConstants.sol";
import {RefundEscrowFactory} from "../../../src/utils/RefundEscrowFactory.sol";

/// @title CHub
/// @notice Struct containing all hub-side contract references for fork tests
struct CHub {
    uint16 centrifugeId;
    // Core
    Gateway gateway;
    MultiAdapter multiAdapter;
    GasService gasService;
    // Admin
    Root root;
    ProtocolGuardian protocolGuardian;
    OpsGuardian opsGuardian;
    // Hub
    HubRegistry hubRegistry;
    Accounting accounting;
    Holdings holdings;
    ShareClassManager shareClassManager;
    Hub hub;
    HubHandler hubHandler;
    BatchRequestManager batchRequestManager;
    // Others
    IdentityValuation identityValuation;
    OracleValuation oracleValuation;
    MockSnapshotHook snapshotHook;
}

/// @title CSpoke
/// @notice Struct containing all spoke-side contract references for fork tests
struct CSpoke {
    uint16 centrifugeId;
    // Core
    Gateway gateway;
    MultiAdapter multiAdapter;
    MessageProcessor messageProcessor;
    // Admin
    Root root;
    ProtocolGuardian protocolGuardian;
    OpsGuardian opsGuardian;
    // Spoke
    BalanceSheet balanceSheet;
    Spoke spoke;
    VaultRegistry vaultRegistry;
    // Vaults
    VaultRouter router;
    bytes32 asyncVaultFactory;
    bytes32 syncDepositVaultFactory;
    AsyncRequestManager asyncRequestManager;
    SyncManager syncManager;
    RefundEscrowFactory refundEscrowFactory;
    // Hooks
    FreezeOnly freezeOnlyHook;
    FullRestrictions fullRestrictionsHook;
    RedemptionRestrictions redemptionRestrictionsHook;
    // Others
    ERC20 usdc;
    AssetId usdcId;
}

/// @title ForkTestBase
/// @notice Base contract for all fork tests, providing common setup and utilities
contract ForkTestBase is Test {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    uint128 constant GAS = IntegrationConstants.GAS;
    uint128 constant HOOK_GAS = IntegrationConstants.HOOK_GAS;

    address immutable ANY = makeAddr("ANY");

    CHub forkHub;
    CSpoke forkSpoke;

    function setUp() public virtual {
        vm.createSelectFork(_rpcEndpoint());
        _loadContracts();
    }

    function _rpcEndpoint() internal view virtual returns (string memory) {
        return IntegrationConstants.RPC_ETHEREUM;
    }

    function _poolAdmin() internal view virtual returns (address) {
        return IntegrationConstants.ETH_DEFAULT_POOL_ADMIN;
    }

    /// @notice Get the pool admin (hub manager) for a specific pool
    /// @dev Base implementation uses default pool admin. Child contracts can override for pool-specific lookup.
    ///      ForkTestInvestmentValidation provides GraphQL-based implementation.
    function _getPoolAdmin(
        PoolId /* poolId */
    )
        internal
        view
        virtual
        returns (address)
    {
        return _poolAdmin(); // Use default pool admin as fallback
    }

    /// @notice Load deployed contract addresses from IntegrationConstants
    /// @dev V3.1: Uses ProtocolGuardian, adds HubHandler, BatchRequestManager, VaultRegistry, RefundEscrowFactory
    ///      NOTE: Some contracts use address(0) placeholders until v3.1 constants are added to IntegrationConstants.sol
    function _loadContracts() internal virtual {
        forkHub = CHub({
            centrifugeId: IntegrationConstants.ETH_CENTRIFUGE_ID,
            // Core
            gateway: Gateway(payable(IntegrationConstants.GATEWAY)),
            multiAdapter: MultiAdapter(IntegrationConstants.MULTI_ADAPTER),
            gasService: GasService(IntegrationConstants.GAS_SERVICE),
            // Admin
            root: Root(IntegrationConstants.ROOT),
            protocolGuardian: ProtocolGuardian(IntegrationConstants.PROTOCOL_GUARDIAN),
            opsGuardian: OpsGuardian(IntegrationConstants.OPS_GUARDIAN),
            // Hub
            hubRegistry: HubRegistry(IntegrationConstants.HUB_REGISTRY),
            accounting: Accounting(IntegrationConstants.ACCOUNTING),
            holdings: Holdings(IntegrationConstants.HOLDINGS),
            shareClassManager: ShareClassManager(IntegrationConstants.SHARE_CLASS_MANAGER),
            hub: Hub(IntegrationConstants.HUB),
            hubHandler: HubHandler(IntegrationConstants.HUB_HANDLER),
            batchRequestManager: BatchRequestManager(IntegrationConstants.BATCH_REQUEST_MANAGER),
            // Others
            identityValuation: IdentityValuation(IntegrationConstants.IDENTITY_VALUATION),
            oracleValuation: OracleValuation(address(0)), // Not yet deployed on forks
            snapshotHook: MockSnapshotHook(address(0)) // Fork tests don't use snapshot hooks
        });

        forkSpoke = CSpoke({
            centrifugeId: IntegrationConstants.ETH_CENTRIFUGE_ID,
            // Core
            gateway: Gateway(payable(IntegrationConstants.GATEWAY)),
            multiAdapter: MultiAdapter(IntegrationConstants.MULTI_ADAPTER),
            messageProcessor: MessageProcessor(IntegrationConstants.MESSAGE_PROCESSOR),
            // Admin
            root: Root(IntegrationConstants.ROOT),
            protocolGuardian: ProtocolGuardian(IntegrationConstants.PROTOCOL_GUARDIAN),
            opsGuardian: OpsGuardian(IntegrationConstants.OPS_GUARDIAN),
            // Spoke
            balanceSheet: BalanceSheet(IntegrationConstants.BALANCE_SHEET),
            spoke: Spoke(IntegrationConstants.SPOKE),
            vaultRegistry: VaultRegistry(IntegrationConstants.VAULT_REGISTRY),
            // Vaults
            router: VaultRouter(IntegrationConstants.ROUTER),
            asyncVaultFactory: IntegrationConstants.ASYNC_VAULT_FACTORY.toBytes32(),
            syncDepositVaultFactory: IntegrationConstants.SYNC_DEPOSIT_VAULT_FACTORY.toBytes32(),
            asyncRequestManager: AsyncRequestManager(payable(IntegrationConstants.ASYNC_REQUEST_MANAGER)),
            syncManager: SyncManager(IntegrationConstants.SYNC_MANAGER),
            refundEscrowFactory: RefundEscrowFactory(IntegrationConstants.REFUND_ESCROW_FACTORY),
            // Hooks
            freezeOnlyHook: FreezeOnly(IntegrationConstants.FREEZE_ONLY_HOOK),
            fullRestrictionsHook: FullRestrictions(IntegrationConstants.FULL_RESTRICTIONS_HOOK),
            redemptionRestrictionsHook: RedemptionRestrictions(IntegrationConstants.REDEMPTION_RESTRICTIONS_HOOK),
            // Others
            usdc: ERC20(address(0)), // NOTE: Unused in fork tests in order to be chain agnostic
            usdcId: newAssetId(0) // NOTE: Unused in fork tests in order to be chain agnostic
        });

        // Fund pool admin
        vm.deal(_poolAdmin(), 10 ether);
    }

    /// @notice Load contract addresses from FullDeployer
    function _loadContractsFromDeployer(FullDeployer deploy) public virtual {
        // Update forkHub with v3.1 addresses
        forkHub.gateway = Gateway(payable(address(deploy.gateway())));
        forkHub.multiAdapter = MultiAdapter(address(deploy.multiAdapter()));
        forkHub.gasService = GasService(address(deploy.gasService()));
        forkHub.root = Root(address(deploy.root()));
        forkHub.protocolGuardian = ProtocolGuardian(address(deploy.protocolGuardian()));
        forkHub.opsGuardian = OpsGuardian(address(deploy.opsGuardian()));
        forkHub.hubRegistry = HubRegistry(address(deploy.hubRegistry()));
        forkHub.accounting = Accounting(address(deploy.accounting()));
        forkHub.holdings = Holdings(address(deploy.holdings()));
        forkHub.shareClassManager = ShareClassManager(address(deploy.shareClassManager()));
        forkHub.hub = Hub(address(deploy.hub()));
        forkHub.hubHandler = HubHandler(address(deploy.hubHandler()));
        forkHub.batchRequestManager = BatchRequestManager(address(deploy.batchRequestManager()));
        forkHub.identityValuation = IdentityValuation(address(deploy.identityValuation()));

        // Update forkSpoke with v3.1 addresses
        forkSpoke.centrifugeId = MessageDispatcher(address(deploy.messageDispatcher())).localCentrifugeId();
        forkSpoke.gateway = Gateway(payable(address(deploy.gateway())));
        forkSpoke.multiAdapter = MultiAdapter(address(deploy.multiAdapter()));
        forkSpoke.messageProcessor = MessageProcessor(address(deploy.messageProcessor()));
        forkSpoke.root = Root(address(deploy.root()));
        forkSpoke.protocolGuardian = ProtocolGuardian(address(deploy.protocolGuardian()));
        forkSpoke.opsGuardian = OpsGuardian(address(deploy.opsGuardian()));
        forkSpoke.balanceSheet = BalanceSheet(address(deploy.balanceSheet()));
        forkSpoke.spoke = Spoke(address(deploy.spoke()));
        forkSpoke.vaultRegistry = VaultRegistry(address(deploy.vaultRegistry()));
        forkSpoke.router = VaultRouter(address(deploy.vaultRouter()));
        forkSpoke.asyncVaultFactory = address(deploy.asyncVaultFactory()).toBytes32();
        forkSpoke.syncDepositVaultFactory = address(deploy.syncDepositVaultFactory()).toBytes32();
        forkSpoke.asyncRequestManager = AsyncRequestManager(payable(address(deploy.asyncRequestManager())));
        forkSpoke.syncManager = SyncManager(address(deploy.syncManager()));
        forkSpoke.refundEscrowFactory = RefundEscrowFactory(address(deploy.refundEscrowFactory()));
        forkSpoke.freezeOnlyHook = FreezeOnly(address(deploy.freezeOnlyHook()));
        forkSpoke.fullRestrictionsHook = FullRestrictions(address(deploy.fullRestrictionsHook()));
        forkSpoke.redemptionRestrictionsHook = RedemptionRestrictions(address(deploy.redemptionRestrictionsHook()));
    }

    /// @notice Create restriction member update message
    function _updateRestrictionMemberMsg(address addr) internal pure returns (bytes memory) {
        return UpdateRestrictionMessageLib.UpdateRestrictionMember({
                user: addr.toBytes32(), validUntil: type(uint64).max
            }).serialize();
    }

    /// @notice Add a pool member with transfer permissions
    function _addPoolMember(IBaseVault vault, address user) internal virtual {
        _addPoolMemberRaw(vault.poolId(), vault.scId(), user);
    }

    /// @notice Add a user as pool member using raw pool/shareClass IDs
    function _addPoolMemberRaw(PoolId poolId, ShareClassId scId, address user) internal virtual {
        vm.startPrank(_getPoolAdmin(poolId));
        forkHub.hub.updateRestriction{value: GAS}(
            poolId, scId, forkSpoke.centrifugeId, _updateRestrictionMemberMsg(user), HOOK_GAS, address(this)
        );
        vm.stopPrank();
    }

    /// @notice Configure prices for a pool (fork-specific version that skips valuation.setPrice())
    function _baseConfigurePrices(PoolId poolId, ShareClassId shareClassId, AssetId assetId, address poolManager)
        internal
        virtual
    {
        vm.startPrank(poolManager);
        forkHub.hub
            .updateSharePrice(poolId, shareClassId, IntegrationConstants.identityPrice(), uint64(block.timestamp));
        forkHub.hub.notifySharePrice{value: GAS}(poolId, shareClassId, forkSpoke.centrifugeId, address(this));
        forkHub.hub.notifyAssetPrice{value: GAS}(poolId, shareClassId, assetId, address(this));
        vm.stopPrank();
    }

    function _isShareToken(address token) internal view returns (bool) {
        try IERC165(token).supportsInterface(type(IERC7575Share).interfaceId) returns (bool supported) {
            return supported;
        } catch {
            return false;
        }
    }

    function _getAsyncVault(PoolId poolId, ShareClassId shareClassId, AssetId assetId)
        internal
        view
        returns (address vaultAddr)
    {
        return address(forkSpoke.vaultRegistry.vault(poolId, shareClassId, assetId, forkSpoke.asyncRequestManager));
    }
}
