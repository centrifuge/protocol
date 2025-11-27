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
import {RefundEscrowFactory} from "../../../src/vaults/factories/RefundEscrowFactory.sol";

import "forge-std/Test.sol";

import {IntegrationConstants} from "../utils/IntegrationConstants.sol";

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

    /// @notice Create restriction member update message
    function _updateRestrictionMemberMsg(address addr) internal pure returns (bytes memory) {
        return UpdateRestrictionMessageLib.UpdateRestrictionMember({
                user: addr.toBytes32(), validUntil: type(uint64).max
            }).serialize();
    }

    /// @notice Add a pool member with transfer permissions
    function _addPoolMember(IBaseVault vault, address user) internal virtual {
        vm.startPrank(_poolAdmin());
        forkHub.hub
            .updateRestriction(
                vault.poolId(),
                vault.scId(),
                forkSpoke.centrifugeId,
                _updateRestrictionMemberMsg(user),
                HOOK_GAS,
                address(this) // refund address
            );
        vm.stopPrank();
    }

    /// @notice Configure prices for a pool (fork-specific version that skips valuation.setPrice())
    function _baseConfigurePrices(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager
    ) internal virtual {
        vm.startPrank(poolManager);
        hub.hub.updateSharePrice(poolId, shareClassId, IntegrationConstants.identityPrice(), uint64(block.timestamp));
        hub.hub.notifySharePrice(poolId, shareClassId, spoke.centrifugeId, address(this));
        hub.hub.notifyAssetPrice(poolId, shareClassId, assetId, address(this));
        vm.stopPrank();
    }

    function _isShareToken(address token) internal view returns (bool) {
        try IERC165(token).supportsInterface(type(IERC7575Share).interfaceId) returns (bool supported) {
            return supported;
        } catch {
            return false;
        }
    }

    function _getAsyncVault(CSpoke memory spoke, PoolId poolId, ShareClassId shareClassId, AssetId assetId)
        internal
        view
        returns (address vaultAddr)
    {
        return address(spoke.vaultRegistry.vault(poolId, shareClassId, assetId, spoke.asyncRequestManager));
    }
}
