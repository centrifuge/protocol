// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";
import {IntegrationConstants} from "./IntegrationConstants.sol";

import {ERC20} from "../../src/misc/ERC20.sol";
import {D18} from "../../src/misc/types/D18.sol";
import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {MockValuation} from "../common/mocks/MockValuation.sol";

import {Root} from "../../src/common/Root.sol";
import {Gateway} from "../../src/common/Gateway.sol";
import {Guardian} from "../../src/common/Guardian.sol";
import {PoolId} from "../../src/common/types/PoolId.sol";
import {AssetId} from "../../src/common/types/AssetId.sol";
import {GasService} from "../../src/common/GasService.sol";
import {IRoot} from "../../src/common/interfaces/IRoot.sol";
import {ShareClassId} from "../../src/common/types/ShareClassId.sol";

import {Hub} from "../../src/hub/Hub.sol";
import {Holdings} from "../../src/hub/Holdings.sol";
import {Accounting} from "../../src/hub/Accounting.sol";
import {HubRegistry} from "../../src/hub/HubRegistry.sol";
import {ShareClassManager} from "../../src/hub/ShareClassManager.sol";

import {Spoke} from "../../src/spoke/Spoke.sol";
import {BalanceSheet} from "../../src/spoke/BalanceSheet.sol";

import {SyncManager} from "../../src/vaults/SyncManager.sol";
import {VaultRouter} from "../../src/vaults/VaultRouter.sol";
import {IBaseVault} from "../../src/vaults/interfaces/IBaseVault.sol";
import {AsyncRequestManager} from "../../src/vaults/AsyncRequestManager.sol";

import {MockSnapshotHook} from "../hooks/mocks/MockSnapshotHook.sol";

import {FreezeOnly} from "../../src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "../../src/hooks/FullRestrictions.sol";
import {RedemptionRestrictions} from "../../src/hooks/RedemptionRestrictions.sol";

import {IdentityValuation} from "../../src/valuations/IdentityValuation.sol";

import "forge-std/Test.sol";

contract ForkTestBase is EndToEndFlows {
    using CastLib for *;

    CHub forkHub;
    CSpoke forkSpoke;

    function setUp() public virtual override {
        vm.createSelectFork(_rpcEndpoint());
        _loadContracts();
    }

    function _rpcEndpoint() internal view virtual returns (string memory) {
        return IntegrationConstants.RPC_ETHEREUM;
    }

    function _poolAdmin() internal pure virtual returns (address) {
        return IntegrationConstants.ETH_DEFAULT_POOL_ADMIN;
    }

    function _loadContracts() internal virtual {
        forkHub = CHub({
            centrifugeId: IntegrationConstants.ETH_CENTRIFUGE_ID,
            root: Root(IntegrationConstants.ROOT),
            guardian: Guardian(IntegrationConstants.GUARDIAN),
            gateway: Gateway(payable(IntegrationConstants.GATEWAY)),
            gasService: GasService(IntegrationConstants.GAS_SERVICE),
            hubRegistry: HubRegistry(IntegrationConstants.HUB_REGISTRY),
            accounting: Accounting(IntegrationConstants.ACCOUNTING),
            holdings: Holdings(IntegrationConstants.HOLDINGS),
            shareClassManager: ShareClassManager(IntegrationConstants.SHARE_CLASS_MANAGER),
            hub: Hub(IntegrationConstants.HUB),
            identityValuation: IdentityValuation(IntegrationConstants.IDENTITY_VALUATION),
            valuation: MockValuation(address(0)), // Fork tests don't use dynamic pricing
            snapshotHook: MockSnapshotHook(address(0)) // Fork tests don't use snapshot hooks
        });

        forkSpoke = CSpoke({
            centrifugeId: IntegrationConstants.ETH_CENTRIFUGE_ID,
            root: Root(IntegrationConstants.ROOT),
            guardian: Guardian(IntegrationConstants.GUARDIAN),
            gateway: Gateway(payable(IntegrationConstants.GATEWAY)),
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
            usdc: ERC20(IntegrationConstants.ETH_USDC),
            usdcId: Spoke(IntegrationConstants.SPOKE).assetToId(IntegrationConstants.ETH_USDC, 0)
        });

        // Initialize pricing state
        currentAssetPrice = IntegrationConstants.identityPrice();
        currentSharePrice = IntegrationConstants.identityPrice();

        // Fund pool admin
        vm.deal(_poolAdmin(), 10 ether);
    }

    function _addPoolMember(IBaseVault vault, address user) internal virtual {
        vm.startPrank(_poolAdmin());
        forkHub.hub.updateRestriction{value: GAS}(
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
        address poolManager,
        D18 assetPrice,
        D18 sharePrice
    ) internal virtual override {
        currentAssetPrice = assetPrice;
        currentSharePrice = sharePrice;

        vm.startPrank(poolManager);
        hub.hub.updateSharePrice(poolId, shareClassId, sharePrice);
        hub.hub.notifySharePrice{value: GAS}(poolId, shareClassId, spoke.centrifugeId);
        hub.hub.notifyAssetPrice{value: GAS}(poolId, shareClassId, assetId);
        vm.stopPrank();
    }
}

contract ForkTestAsyncInvestments is ForkTestBase {
    // TODO(later): After v2 disable, switch to JAAA
    IBaseVault constant VAULT = IBaseVault(IntegrationConstants.ETH_DEJAAA_VAULT);

    uint128 constant depositAmount = IntegrationConstants.DEFAULT_USDC_AMOUNT;

    function test_completeAsyncDepositFlow() public {
        _completeAsyncDeposit(VAULT, makeAddr("INVESTOR_A"), depositAmount);
    }

    function test_completeAsyncRedeemFlow() public {
        _completeAsyncRedeem(VAULT, makeAddr("INVESTOR_A"), depositAmount);
    }

    function _completeAsyncDeposit(IBaseVault vault, address investor, uint128 amount) internal {
        deal(vault.asset(), investor, amount);
        _addPoolMember(vault, investor);

        _asyncDepositFlow(
            forkHub,
            forkSpoke,
            vault.poolId(),
            vault.scId(),
            forkSpoke.usdcId,
            _poolAdmin(),
            investor,
            amount,
            true,
            true,
            address(vault)
        );
    }

    function _completeAsyncRedeem(IBaseVault vault, address investor, uint128 amount) internal {
        _completeAsyncDeposit(vault, investor, amount);

        _syncRedeemFlow(
            forkHub,
            forkSpoke,
            vault.poolId(),
            vault.scId(),
            forkSpoke.usdcId,
            _poolAdmin(),
            investor,
            true,
            true,
            address(vault)
        );
    }
}

contract ForkTestSyncInvestments is ForkTestBase {
    using CastLib for *;

    IBaseVault constant VAULT = IBaseVault(IntegrationConstants.PLUME_SYNC_DEPOSIT_VAULT);

    function setUp() public override {
        vm.createSelectFork(IntegrationConstants.RPC_PLUME);

        _loadContracts();

        _baseConfigurePrices(
            forkHub,
            forkSpoke,
            VAULT.poolId(),
            VAULT.scId(),
            forkSpoke.usdcId,
            _poolAdmin(),
            IntegrationConstants.identityPrice(),
            IntegrationConstants.identityPrice()
        );
    }

    function _rpcEndpoint() internal pure override returns (string memory) {
        return IntegrationConstants.RPC_PLUME;
    }

    function _poolAdmin() internal pure override returns (address) {
        return IntegrationConstants.PLUME_POOL_ADMIN;
    }

    function _loadContracts() internal override {
        forkHub = CHub({
            centrifugeId: IntegrationConstants.PLUME_CENTRIFUGE_ID,
            root: Root(IntegrationConstants.ROOT),
            guardian: Guardian(IntegrationConstants.GUARDIAN),
            gateway: Gateway(payable(IntegrationConstants.GATEWAY)),
            gasService: GasService(IntegrationConstants.GAS_SERVICE),
            hubRegistry: HubRegistry(IntegrationConstants.HUB_REGISTRY),
            accounting: Accounting(IntegrationConstants.ACCOUNTING),
            holdings: Holdings(IntegrationConstants.HOLDINGS),
            shareClassManager: ShareClassManager(IntegrationConstants.SHARE_CLASS_MANAGER),
            hub: Hub(IntegrationConstants.HUB),
            identityValuation: IdentityValuation(IntegrationConstants.IDENTITY_VALUATION),
            valuation: MockValuation(address(0)), // Fork tests don't use dynamic pricing
            snapshotHook: MockSnapshotHook(address(0)) // Fork tests don't use snapshot hooks
        });

        forkSpoke = CSpoke({
            centrifugeId: IntegrationConstants.PLUME_CENTRIFUGE_ID,
            root: Root(IntegrationConstants.ROOT),
            guardian: Guardian(IntegrationConstants.GUARDIAN),
            gateway: Gateway(payable(IntegrationConstants.GATEWAY)),
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
            usdc: ERC20(IntegrationConstants.PLUME_PUSD),
            usdcId: Spoke(IntegrationConstants.SPOKE).assetToId(IntegrationConstants.PLUME_PUSD, 0)
        });

        // Initialize pricing state
        currentAssetPrice = IntegrationConstants.identityPrice();
        currentSharePrice = IntegrationConstants.identityPrice();

        // Fund pool admin
        vm.deal(_poolAdmin(), 10 ether);
    }

    function test_completeSyncDepositFlow() public {
        _completeSyncDeposit(makeAddr("INVESTOR_A"), 1000e18);
    }

    function test_completeSyncDepositAsyncRedeemFlow() public {
        _completeSyncDepositAsyncRedeem(makeAddr("INVESTOR_A"), 1000e18);
    }

    function _completeSyncDeposit(address investor, uint128 amount) internal {
        _addPoolMember(VAULT, investor);

        deal(address(forkSpoke.usdc), investor, amount);
        _syncDepositFlow(
            forkHub,
            forkSpoke,
            VAULT.poolId(),
            VAULT.scId(),
            forkSpoke.usdcId,
            _poolAdmin(),
            investor,
            amount,
            true,
            true
        );
    }

    function _completeSyncDepositAsyncRedeem(address investor, uint128 amount) internal {
        _completeSyncDeposit(investor, amount);

        _syncRedeemFlow(
            forkHub,
            forkSpoke,
            VAULT.poolId(),
            VAULT.scId(),
            forkSpoke.usdcId,
            _poolAdmin(),
            investor,
            true,
            true,
            address(VAULT)
        );
    }
}

/// @notice Contract for validating live contract permissions and state
contract ForkTestLiveValidation is ForkTestAsyncInvestments {
    /// @notice Validates that V3_ROOT has ward permissions on all Ethereum contracts, vaults, and share tokens
    function _validateV3RootPermissions(IRoot v3Root) internal view {
        // === CONTRACTS WITH ROOT PERMISSIONS (based on deployment scripts) ===

        // From CommonDeployer
        _validateV3RootWard(IntegrationConstants.TOKEN_RECOVERER, "tokenRecoverer", v3Root);

        // From HubDeployer
        _validateV3RootWard(IntegrationConstants.HUB_REGISTRY, "hubRegistry", v3Root);
        _validateV3RootWard(IntegrationConstants.ACCOUNTING, "accounting", v3Root);
        _validateV3RootWard(IntegrationConstants.HOLDINGS, "holdings", v3Root);
        _validateV3RootWard(IntegrationConstants.SHARE_CLASS_MANAGER, "shareClassManager", v3Root);
        _validateV3RootWard(IntegrationConstants.HUB, "hub", v3Root);
        _validateV3RootWard(IntegrationConstants.HUB_HELPERS, "hubHelpers", v3Root);

        // From SpokeDeployer
        _validateV3RootWard(IntegrationConstants.SPOKE, "spoke", v3Root);
        _validateV3RootWard(IntegrationConstants.BALANCE_SHEET, "balanceSheet", v3Root);
        _validateV3RootWard(IntegrationConstants.TOKEN_FACTORY, "tokenFactory", v3Root);
        _validateV3RootWard(IntegrationConstants.CONTRACT_UPDATER, "contractUpdater", v3Root);

        // From VaultsDeployer
        _validateV3RootWard(IntegrationConstants.ROUTER, "vaultRouter", v3Root);
        _validateV3RootWard(IntegrationConstants.ASYNC_REQUEST_MANAGER, "asyncRequestManager", v3Root);
        _validateV3RootWard(IntegrationConstants.SYNC_MANAGER, "syncManager", v3Root);
        _validateV3RootWard(IntegrationConstants.ROUTER_ESCROW, "routerEscrow", v3Root);
        _validateV3RootWard(IntegrationConstants.GLOBAL_ESCROW, "globalEscrow", v3Root);
        _validateV3RootWard(IntegrationConstants.ASYNC_VAULT_FACTORY, "asyncVaultFactory", v3Root);
        _validateV3RootWard(IntegrationConstants.SYNC_DEPOSIT_VAULT_FACTORY, "syncDepositVaultFactory", v3Root);

        // From ValuationsDeployer
        _validateV3RootWard(IntegrationConstants.IDENTITY_VALUATION, "identityValuation", v3Root);

        // === HOOKS (from HooksDeployer) ===
        _validateV3RootWard(IntegrationConstants.FREEZE_ONLY_HOOK, "freezeOnlyHook", v3Root);
        _validateV3RootWard(IntegrationConstants.FULL_RESTRICTIONS_HOOK, "fullRestrictionsHook", v3Root);
        _validateV3RootWard(IntegrationConstants.FREELY_TRANSFERABLE_HOOK, "freelyTransferableHook", v3Root);
        _validateV3RootWard(IntegrationConstants.REDEMPTION_RESTRICTIONS_HOOK, "redemptionRestrictionsHook", v3Root);

        // === ADAPTERS (from AdaptersDeployer) ===
        _validateV3RootWard(IntegrationConstants.WORMHOLE_ADAPTER, "wormholeAdapter", v3Root);
        _validateV3RootWard(IntegrationConstants.AXELAR_ADAPTER, "axelarAdapter", v3Root);

        // === V3 VAULTS ===
        _validateV3RootWard(IntegrationConstants.ETH_JAAA_VAULT, "JAAA V3 vault", v3Root);
        _validateV3RootWard(IntegrationConstants.ETH_JTRSY_VAULT, "JAAA V3 vault", v3Root);
        _validateV3RootWard(IntegrationConstants.ETH_DEJAAA_VAULT, "deJAAA vault", v3Root);
        _validateV3RootWard(IntegrationConstants.ETH_DEJTRSY_VAULT, "deJTRSY vault", v3Root);

        // === SHARE TOKENS ===
        _validateV3RootWard(IntegrationConstants.ETH_JAAA_SHARE_TOKEN, "JAAA share token", v3Root);
        _validateV3RootWard(IntegrationConstants.ETH_JTRSY_SHARE_TOKEN, "JTRSY share token", v3Root);
        _validateV3RootWard(IntegrationConstants.ETH_DEJTRSY_SHARE_TOKEN, "deJTRSY share token", v3Root);
        _validateV3RootWard(IntegrationConstants.ETH_DEJAAA_SHARE_TOKEN, "deJAAA share token", v3Root);
    }

    /// @notice Helper function to validate V3_ROOT has ward permissions on a specific contract
    function _validateV3RootWard(address contractAddr, string memory contractName, IRoot v3Root) internal view {
        if (contractAddr.code.length == 0) {
            revert(string(abi.encodePacked(contractName, " has no code")));
        }

        assertEq(
            IAuth(contractAddr).wards(address(v3Root)),
            1,
            string(
                abi.encodePacked(
                    "V3_ROOT should have ward permissions on ", contractName, " (", vm.toString(contractAddr), ")"
                )
            )
        );
    }
}
