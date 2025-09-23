// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "../../../src/misc/ERC20.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {IERC7575Share, IERC165} from "../../../src/misc/interfaces/IERC7575.sol";

import {Root} from "../../../src/common/Root.sol";
import {Gateway} from "../../../src/common/Gateway.sol";
import {Guardian} from "../../../src/common/Guardian.sol";
import {PoolId} from "../../../src/common/types/PoolId.sol";
import {GasService} from "../../../src/common/GasService.sol";
import {MultiAdapter} from "../../../src/common/MultiAdapter.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../src/common/types/AssetId.sol";

import {Hub} from "../../../src/hub/Hub.sol";
import {Holdings} from "../../../src/hub/Holdings.sol";
import {Accounting} from "../../../src/hub/Accounting.sol";
import {HubHelpers} from "../../../src/hub/HubHelpers.sol";
import {HubRegistry} from "../../../src/hub/HubRegistry.sol";
import {ShareClassManager} from "../../../src/hub/ShareClassManager.sol";

import {Spoke} from "../../../src/spoke/Spoke.sol";
import {BalanceSheet} from "../../../src/spoke/BalanceSheet.sol";
import {UpdateContractMessageLib} from "../../../src/spoke/libraries/UpdateContractMessageLib.sol";
import {IVaultManager, REQUEST_MANAGER_V3_0} from "../../../src/spoke/interfaces/legacy/IVaultManager.sol";

import {SyncManager} from "../../../src/vaults/SyncManager.sol";
import {VaultRouter} from "../../../src/vaults/VaultRouter.sol";
import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {HubRequestManager} from "../../../src/vaults/HubRequestManager.sol";
import {AsyncRequestManager} from "../../../src/vaults/AsyncRequestManager.sol";

import {MockSnapshotHook} from "../../hooks/mocks/MockSnapshotHook.sol";

import {FreezeOnly} from "../../../src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "../../../src/hooks/FullRestrictions.sol";
import {RedemptionRestrictions} from "../../../src/hooks/RedemptionRestrictions.sol";
import {UpdateRestrictionMessageLib} from "../../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {OracleValuation} from "../../../src/valuations/OracleValuation.sol";
import {IdentityValuation} from "../../../src/valuations/IdentityValuation.sol";

import "forge-std/Test.sol";

import {IntegrationConstants} from "../utils/IntegrationConstants.sol";

struct CHub {
    uint16 centrifugeId;
    // Common
    Root root;
    Guardian guardian;
    Gateway gateway;
    MultiAdapter multiAdapter;
    GasService gasService;
    // Hub
    HubRegistry hubRegistry;
    Accounting accounting;
    Holdings holdings;
    ShareClassManager shareClassManager;
    Hub hub;
    // Others
    IdentityValuation identityValuation;
    OracleValuation oracleValuation;
    MockSnapshotHook snapshotHook;
}

struct CSpoke {
    uint16 centrifugeId;
    // Common
    Root root;
    Guardian guardian;
    Gateway gateway;
    MultiAdapter multiAdapter;
    // Vaults
    BalanceSheet balanceSheet;
    Spoke spoke;
    VaultRouter router;
    bytes32 asyncVaultFactory;
    bytes32 syncDepositVaultFactory;
    AsyncRequestManager asyncRequestManager;
    SyncManager syncManager;
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
    using UpdateContractMessageLib for *;
    using UpdateRestrictionMessageLib for *;

    uint128 constant GAS = IntegrationConstants.GAS;
    uint128 constant EXTRA_GAS = IntegrationConstants.EXTRA_GAS;

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

    function _loadContracts() internal virtual {
        forkHub = CHub({
            centrifugeId: IntegrationConstants.ETH_CENTRIFUGE_ID,
            root: Root(IntegrationConstants.ROOT),
            guardian: Guardian(IntegrationConstants.GUARDIAN),
            gateway: Gateway(payable(IntegrationConstants.GATEWAY)),
            multiAdapter: MultiAdapter(IntegrationConstants.MULTI_ADAPTER),
            gasService: GasService(IntegrationConstants.GAS_SERVICE),
            hubRegistry: HubRegistry(IntegrationConstants.HUB_REGISTRY),
            accounting: Accounting(IntegrationConstants.ACCOUNTING),
            holdings: Holdings(IntegrationConstants.HOLDINGS),
            shareClassManager: ShareClassManager(IntegrationConstants.SHARE_CLASS_MANAGER),
            hub: Hub(IntegrationConstants.HUB),
            identityValuation: IdentityValuation(IntegrationConstants.IDENTITY_VALUATION),
            oracleValuation: OracleValuation(address(0)), // TODO: add this once deployed
            snapshotHook: MockSnapshotHook(address(0)) // Fork tests don't use snapshot hooks
        });

        forkSpoke = CSpoke({
            centrifugeId: IntegrationConstants.ETH_CENTRIFUGE_ID,
            root: Root(IntegrationConstants.ROOT),
            guardian: Guardian(IntegrationConstants.GUARDIAN),
            gateway: Gateway(payable(IntegrationConstants.GATEWAY)),
            multiAdapter: MultiAdapter(IntegrationConstants.MULTI_ADAPTER),
            balanceSheet: BalanceSheet(IntegrationConstants.BALANCE_SHEET),
            spoke: Spoke(IntegrationConstants.SPOKE),
            router: VaultRouter(IntegrationConstants.ROUTER),
            asyncVaultFactory: IntegrationConstants.ASYNC_VAULT_FACTORY.toBytes32(),
            syncDepositVaultFactory: IntegrationConstants.SYNC_DEPOSIT_VAULT_FACTORY.toBytes32(),
            asyncRequestManager: AsyncRequestManager(IntegrationConstants.ASYNC_REQUEST_MANAGER),
            syncManager: SyncManager(IntegrationConstants.SYNC_MANAGER),
            freezeOnlyHook: FreezeOnly(IntegrationConstants.FREEZE_ONLY_HOOK),
            fullRestrictionsHook: FullRestrictions(IntegrationConstants.FULL_RESTRICTIONS_HOOK),
            redemptionRestrictionsHook: RedemptionRestrictions(IntegrationConstants.REDEMPTION_RESTRICTIONS_HOOK),
            usdc: ERC20(address(0)), // NOTE: Unused in fork tests in order to be chain agnostic
            usdcId: newAssetId(0) // NOTE: Unused in fork tests in order to be chain agnostic
        });

        // Fund pool admin
        vm.deal(_poolAdmin(), 10 ether);
    }

    function _updateRestrictionMemberMsg(address addr) internal pure returns (bytes memory) {
        return UpdateRestrictionMessageLib.UpdateRestrictionMember({
            user: addr.toBytes32(),
            validUntil: type(uint64).max
        }).serialize();
    }

    function _addPoolMember(IBaseVault vault, address user) internal virtual {
        vm.startPrank(_poolAdmin());
        forkHub.hub.updateRestriction(
            vault.poolId(), vault.scId(), forkSpoke.centrifugeId, _updateRestrictionMemberMsg(user), EXTRA_GAS
        );
        vm.stopPrank();
    }

    /// @dev Override to handle fork-specific price configuration
    /// Skip valuation.setPrice() since valuation is address(0) for fork tests
    function _baseConfigurePrices(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager
    ) internal virtual {
        vm.startPrank(poolManager);
        hub.hub.updateSharePrice(poolId, shareClassId, IntegrationConstants.identityPrice());
        hub.hub.notifySharePrice(poolId, shareClassId, spoke.centrifugeId);
        hub.hub.notifyAssetPrice(poolId, shareClassId, assetId);
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
        if (spoke.asyncRequestManager == REQUEST_MANAGER_V3_0) {
            // Fallback to legacy V3.0 lookup if not found in new system
            return
                address(IVaultManager(address(spoke.asyncRequestManager)).vaultByAssetId(poolId, shareClassId, assetId));
        } else {
            // Try new system first
            return address(spoke.spoke.vault(poolId, shareClassId, assetId, spoke.asyncRequestManager));
        }
    }

    function _updateContractSyncDepositMaxReserveMsg(AssetId assetId, uint128 maxReserve)
        internal
        pure
        returns (bytes memory)
    {
        return UpdateContractMessageLib.UpdateContractSyncDepositMaxReserve({
            assetId: assetId.raw(),
            maxReserve: maxReserve
        }).serialize();
    }
}
