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

import {Escrow} from "../../src/misc/Escrow.sol";
import {TokenFactory} from "../../src/spoke/factories/TokenFactory.sol";
import {HubHelpers} from "../../src/hub/HubHelpers.sol";
import {MessageProcessor} from "../../src/common/MessageProcessor.sol";
import {MessageDispatcher} from "../../src/common/MessageDispatcher.sol";
import {MultiAdapter} from "../../src/common/MultiAdapter.sol";
import {PoolEscrowFactory} from "../../src/common/factories/PoolEscrowFactory.sol";
import {IPoolEscrowFactory} from "../../src/common/factories/interfaces/IPoolEscrowFactory.sol";
import {IMessageProcessor} from "../../src/common/interfaces/IMessageProcessor.sol";
import {IMessageDispatcher} from "../../src/common/interfaces/IMessageDispatcher.sol";
import {WormholeAdapter} from "../../src/adapters/WormholeAdapter.sol";
import {AxelarAdapter} from "../../src/adapters/AxelarAdapter.sol";
import {IAdapter} from "../../src/common/interfaces/IAdapter.sol";
import {WormholeSource, WormholeDestination} from "../../src/adapters/interfaces/IWormholeAdapter.sol";
import {AxelarSource, AxelarDestination} from "../../src/adapters/interfaces/IAxelarAdapter.sol";

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
    function test_validateCompleteDeployment() public view {
        validateDeployment();
    }

    /// @notice Validates wards and filings of core protocol contracts, vaults and share tokens
    function validateDeployment() public view {
        _validateV3RootPermissions();
        _validateContractWardRelationships();
        _validateFileConfigurations();
        _validateEndorsements();
        _validateGuardianAdapterConfigurations();
        _validateAdapterSourceDestinationMappings();
    }

    /// @notice Validates that root has ward permissions on all core protocol contracts, vaults, and share tokens
    function _validateV3RootPermissions() internal view {
        // From CommonDeployer
        _validateRootWard(IntegrationConstants.TOKEN_RECOVERER);

        // From HubDeployer
        _validateRootWard(IntegrationConstants.HUB_REGISTRY);
        _validateRootWard(IntegrationConstants.ACCOUNTING);
        _validateRootWard(IntegrationConstants.HOLDINGS);
        _validateRootWard(IntegrationConstants.SHARE_CLASS_MANAGER);
        _validateRootWard(IntegrationConstants.HUB);
        _validateRootWard(IntegrationConstants.HUB_HELPERS);

        // From SpokeDeployer
        _validateRootWard(IntegrationConstants.SPOKE);
        _validateRootWard(IntegrationConstants.BALANCE_SHEET);
        _validateRootWard(IntegrationConstants.TOKEN_FACTORY);
        _validateRootWard(IntegrationConstants.CONTRACT_UPDATER);

        // From VaultsDeployer
        _validateRootWard(IntegrationConstants.ROUTER);
        _validateRootWard(IntegrationConstants.ASYNC_REQUEST_MANAGER);
        _validateRootWard(IntegrationConstants.SYNC_MANAGER);
        _validateRootWard(IntegrationConstants.ROUTER_ESCROW);
        _validateRootWard(IntegrationConstants.GLOBAL_ESCROW);
        _validateRootWard(IntegrationConstants.ASYNC_VAULT_FACTORY);
        _validateRootWard(IntegrationConstants.SYNC_DEPOSIT_VAULT_FACTORY);

        // From ValuationsDeployer
        _validateRootWard(IntegrationConstants.IDENTITY_VALUATION);

        // From HooksDeployer
        _validateRootWard(IntegrationConstants.FREEZE_ONLY_HOOK);
        _validateRootWard(IntegrationConstants.FULL_RESTRICTIONS_HOOK);
        _validateRootWard(IntegrationConstants.FREELY_TRANSFERABLE_HOOK);
        _validateRootWard(IntegrationConstants.REDEMPTION_RESTRICTIONS_HOOK);

        // From VaultsDeployer
        _validateRootWard(IntegrationConstants.WORMHOLE_ADAPTER);
        _validateRootWard(IntegrationConstants.AXELAR_ADAPTER);

        _validateRootWard(IntegrationConstants.ETH_JAAA_VAULT);
        _validateRootWard(IntegrationConstants.ETH_JTRSY_VAULT);
        _validateRootWard(IntegrationConstants.ETH_DEJAAA_VAULT);
        _validateRootWard(IntegrationConstants.ETH_DEJTRSY_VAULT);

        _validateRootWard(IntegrationConstants.ETH_JAAA_SHARE_TOKEN);
        _validateRootWard(IntegrationConstants.ETH_JTRSY_SHARE_TOKEN);
        _validateRootWard(IntegrationConstants.ETH_DEJTRSY_SHARE_TOKEN);
        _validateRootWard(IntegrationConstants.ETH_DEJAAA_SHARE_TOKEN);
    }

    /// @notice Optimized ROOT ward validation using VM labels
    function _validateRootWard(address contractAddr) internal view {
        require(contractAddr.code.length > 0, "Contract has no code");
        assertEq(IAuth(contractAddr).wards(IntegrationConstants.ROOT), 1);
    }

    /// @notice Validates all contract-to-contract ward relationships based on deployment scripts
    function _validateContractWardRelationships() internal view {
        // CommonDeployer
        _validateWard(IntegrationConstants.ROOT, IntegrationConstants.GUARDIAN);
        _validateWard(IntegrationConstants.ROOT, IntegrationConstants.TOKEN_RECOVERER);
        _validateWard(IntegrationConstants.ROOT, IntegrationConstants.MESSAGE_PROCESSOR);
        _validateWard(IntegrationConstants.ROOT, IntegrationConstants.MESSAGE_DISPATCHER);
        _validateWard(IntegrationConstants.GATEWAY, IntegrationConstants.ROOT);
        _validateWard(IntegrationConstants.GATEWAY, IntegrationConstants.MESSAGE_DISPATCHER);
        _validateWard(IntegrationConstants.GATEWAY, IntegrationConstants.MULTI_ADAPTER);
        _validateWard(IntegrationConstants.GATEWAY, IntegrationConstants.HUB);
        _validateWard(IntegrationConstants.GATEWAY, IntegrationConstants.SPOKE);
        _validateWard(IntegrationConstants.GATEWAY, IntegrationConstants.BALANCE_SHEET);
        _validateWard(IntegrationConstants.GATEWAY, IntegrationConstants.ROUTER);
        _validateWard(IntegrationConstants.MULTI_ADAPTER, IntegrationConstants.ROOT);
        _validateWard(IntegrationConstants.MULTI_ADAPTER, IntegrationConstants.GUARDIAN);
        _validateWard(IntegrationConstants.MULTI_ADAPTER, IntegrationConstants.GATEWAY);
        _validateWard(IntegrationConstants.MESSAGE_DISPATCHER, IntegrationConstants.ROOT);
        _validateWard(IntegrationConstants.MESSAGE_DISPATCHER, IntegrationConstants.GUARDIAN);
        _validateWard(IntegrationConstants.MESSAGE_DISPATCHER, IntegrationConstants.HUB);
        _validateWard(IntegrationConstants.MESSAGE_DISPATCHER, IntegrationConstants.HUB_HELPERS);
        _validateWard(IntegrationConstants.MESSAGE_DISPATCHER, IntegrationConstants.SPOKE);
        _validateWard(IntegrationConstants.MESSAGE_DISPATCHER, IntegrationConstants.BALANCE_SHEET);
        _validateWard(IntegrationConstants.MESSAGE_PROCESSOR, IntegrationConstants.ROOT);
        _validateWard(IntegrationConstants.MESSAGE_PROCESSOR, IntegrationConstants.GATEWAY);
        _validateWard(IntegrationConstants.TOKEN_RECOVERER, IntegrationConstants.ROOT);
        _validateWard(IntegrationConstants.TOKEN_RECOVERER, IntegrationConstants.MESSAGE_DISPATCHER);
        _validateWard(IntegrationConstants.TOKEN_RECOVERER, IntegrationConstants.MESSAGE_PROCESSOR);
        _validateWard(IntegrationConstants.POOL_ESCROW_FACTORY, IntegrationConstants.ROOT);
        _validateWard(IntegrationConstants.POOL_ESCROW_FACTORY, IntegrationConstants.HUB);
        _validateWard(IntegrationConstants.POOL_ESCROW_FACTORY, IntegrationConstants.SPOKE);

        // HubDeployer
        _validateWard(IntegrationConstants.HUB_REGISTRY, IntegrationConstants.HUB);
        _validateWard(IntegrationConstants.HOLDINGS, IntegrationConstants.HUB);
        _validateWard(IntegrationConstants.ACCOUNTING, IntegrationConstants.HUB);
        _validateWard(IntegrationConstants.SHARE_CLASS_MANAGER, IntegrationConstants.HUB);
        _validateWard(IntegrationConstants.HUB_HELPERS, IntegrationConstants.HUB);
        _validateWard(IntegrationConstants.HUB, IntegrationConstants.MESSAGE_PROCESSOR);
        _validateWard(IntegrationConstants.HUB, IntegrationConstants.MESSAGE_DISPATCHER);
        _validateWard(IntegrationConstants.HUB, IntegrationConstants.GUARDIAN);
        _validateWard(IntegrationConstants.ACCOUNTING, IntegrationConstants.HUB_HELPERS);
        _validateWard(IntegrationConstants.SHARE_CLASS_MANAGER, IntegrationConstants.HUB_HELPERS);

        // SpokeDeployer
        _validateWard(IntegrationConstants.TOKEN_FACTORY, IntegrationConstants.SPOKE);
        _validateWard(IntegrationConstants.SPOKE, IntegrationConstants.MESSAGE_PROCESSOR);
        _validateWard(IntegrationConstants.SPOKE, IntegrationConstants.MESSAGE_DISPATCHER);
        _validateWard(IntegrationConstants.BALANCE_SHEET, IntegrationConstants.MESSAGE_PROCESSOR);
        _validateWard(IntegrationConstants.BALANCE_SHEET, IntegrationConstants.MESSAGE_DISPATCHER);
        _validateWard(IntegrationConstants.CONTRACT_UPDATER, IntegrationConstants.MESSAGE_PROCESSOR);
        _validateWard(IntegrationConstants.CONTRACT_UPDATER, IntegrationConstants.MESSAGE_DISPATCHER);

        // VaultsDeployer
        _validateWard(IntegrationConstants.ASYNC_VAULT_FACTORY, IntegrationConstants.SPOKE);
        _validateWard(IntegrationConstants.SYNC_DEPOSIT_VAULT_FACTORY, IntegrationConstants.SPOKE);
        _validateWard(IntegrationConstants.ASYNC_REQUEST_MANAGER, IntegrationConstants.SPOKE);
        _validateWard(IntegrationConstants.SYNC_MANAGER, IntegrationConstants.CONTRACT_UPDATER);
        _validateWard(IntegrationConstants.GLOBAL_ESCROW, IntegrationConstants.ASYNC_REQUEST_MANAGER);
        _validateWard(IntegrationConstants.ROUTER_ESCROW, IntegrationConstants.ROUTER);
        // TODO: Ensure Missing syncManager <- syncDepositVaultFactory relationship is expected
        _validateWard(IntegrationConstants.ASYNC_REQUEST_MANAGER, IntegrationConstants.SYNC_DEPOSIT_VAULT_FACTORY);
        _validateWard(IntegrationConstants.ASYNC_REQUEST_MANAGER, IntegrationConstants.ASYNC_VAULT_FACTORY);

        // HooksDeployer
        _validateWard(IntegrationConstants.FREEZE_ONLY_HOOK, IntegrationConstants.SPOKE);
        _validateWard(IntegrationConstants.FULL_RESTRICTIONS_HOOK, IntegrationConstants.SPOKE);
        _validateWard(IntegrationConstants.FREELY_TRANSFERABLE_HOOK, IntegrationConstants.SPOKE);
        _validateWard(IntegrationConstants.REDEMPTION_RESTRICTIONS_HOOK, IntegrationConstants.SPOKE);
    }

    /// @notice Validates file configurations set during deployment
    function _validateFileConfigurations() internal view {
        // CommonDeployer configs
        assertEq(
            address(Gateway(payable(IntegrationConstants.GATEWAY)).processor()), IntegrationConstants.MESSAGE_PROCESSOR
        );
        assertEq(address(Gateway(payable(IntegrationConstants.GATEWAY)).adapter()), IntegrationConstants.MULTI_ADAPTER);
        assertEq(PoolEscrowFactory(IntegrationConstants.POOL_ESCROW_FACTORY).gateway(), IntegrationConstants.GATEWAY);
        assertEq(address(Guardian(IntegrationConstants.GUARDIAN).safe()), IntegrationConstants.ADMIN_SAFE);

        // HubDeployer Configs
        assertEq(address(MessageProcessor(IntegrationConstants.MESSAGE_PROCESSOR).hub()), IntegrationConstants.HUB);
        assertEq(address(MessageDispatcher(IntegrationConstants.MESSAGE_DISPATCHER).hub()), IntegrationConstants.HUB);
        assertEq(address(Hub(IntegrationConstants.HUB).sender()), IntegrationConstants.MESSAGE_DISPATCHER);
        assertEq(address(Hub(IntegrationConstants.HUB).poolEscrowFactory()), IntegrationConstants.POOL_ESCROW_FACTORY);
        assertEq(address(Guardian(IntegrationConstants.GUARDIAN).hub()), IntegrationConstants.HUB);
        assertEq(address(HubHelpers(IntegrationConstants.HUB_HELPERS).hub()), IntegrationConstants.HUB);

        // SpokeDeployer configs
        assertEq(
            address(MessageDispatcher(IntegrationConstants.MESSAGE_DISPATCHER).spoke()), IntegrationConstants.SPOKE
        );
        assertEq(
            address(MessageDispatcher(IntegrationConstants.MESSAGE_DISPATCHER).balanceSheet()),
            IntegrationConstants.BALANCE_SHEET
        );
        assertEq(
            address(MessageDispatcher(IntegrationConstants.MESSAGE_DISPATCHER).contractUpdater()),
            IntegrationConstants.CONTRACT_UPDATER
        );

        assertEq(address(MessageProcessor(IntegrationConstants.MESSAGE_PROCESSOR).spoke()), IntegrationConstants.SPOKE);
        assertEq(
            address(MessageProcessor(IntegrationConstants.MESSAGE_PROCESSOR).balanceSheet()),
            IntegrationConstants.BALANCE_SHEET
        );
        assertEq(
            address(MessageProcessor(IntegrationConstants.MESSAGE_PROCESSOR).contractUpdater()),
            IntegrationConstants.CONTRACT_UPDATER
        );

        assertEq(address(Spoke(IntegrationConstants.SPOKE).gateway()), IntegrationConstants.GATEWAY);
        assertEq(address(Spoke(IntegrationConstants.SPOKE).sender()), IntegrationConstants.MESSAGE_DISPATCHER);
        assertEq(
            address(Spoke(IntegrationConstants.SPOKE).poolEscrowFactory()), IntegrationConstants.POOL_ESCROW_FACTORY
        );

        assertEq(address(BalanceSheet(IntegrationConstants.BALANCE_SHEET).spoke()), IntegrationConstants.SPOKE);
        assertEq(
            address(BalanceSheet(IntegrationConstants.BALANCE_SHEET).sender()), IntegrationConstants.MESSAGE_DISPATCHER
        );
        assertEq(address(BalanceSheet(IntegrationConstants.BALANCE_SHEET).gateway()), IntegrationConstants.GATEWAY);
        assertEq(
            address(BalanceSheet(IntegrationConstants.BALANCE_SHEET).poolEscrowProvider()),
            IntegrationConstants.POOL_ESCROW_FACTORY
        );

        assertEq(
            PoolEscrowFactory(IntegrationConstants.POOL_ESCROW_FACTORY).balanceSheet(),
            IntegrationConstants.BALANCE_SHEET
        );

        TokenFactory factory = TokenFactory(IntegrationConstants.TOKEN_FACTORY);
        assertEq(factory.tokenWards(0), IntegrationConstants.SPOKE);
        assertEq(factory.tokenWards(1), IntegrationConstants.BALANCE_SHEET);

        // VaultsDeployer configs
        assertEq(
            address(AsyncRequestManager(IntegrationConstants.ASYNC_REQUEST_MANAGER).spoke()), IntegrationConstants.SPOKE
        );
        assertEq(
            address(AsyncRequestManager(IntegrationConstants.ASYNC_REQUEST_MANAGER).balanceSheet()),
            IntegrationConstants.BALANCE_SHEET
        );

        assertEq(address(SyncManager(IntegrationConstants.SYNC_MANAGER).spoke()), IntegrationConstants.SPOKE);
        assertEq(
            address(SyncManager(IntegrationConstants.SYNC_MANAGER).balanceSheet()), IntegrationConstants.BALANCE_SHEET
        );
    }

    /// @notice Validates endorsements from Root
    function _validateEndorsements() internal view {
        // From VaultsDeployer
        assertEq(
            IRoot(IntegrationConstants.ROOT).endorsements(IntegrationConstants.ASYNC_REQUEST_MANAGER),
            1,
            "AsyncRequestManager not endorsed by Root"
        );
        assertEq(
            IRoot(IntegrationConstants.ROOT).endorsements(IntegrationConstants.GLOBAL_ESCROW),
            1,
            "GlobalEscrow not endorsed by Root"
        );
        assertEq(
            IRoot(IntegrationConstants.ROOT).endorsements(IntegrationConstants.ROUTER),
            1,
            "VaultRouter not endorsed by Root"
        );

        // From SpokeDeployer
        assertEq(
            IRoot(IntegrationConstants.ROOT).endorsements(IntegrationConstants.BALANCE_SHEET),
            1,
            "BalanceSheet not endorsed by Root"
        );
    }

    /// @notice Validates Guardian adapter configurations for all connected chains
    function _validateGuardianAdapterConfigurations() internal view {
        MultiAdapter multiAdapter = MultiAdapter(IntegrationConstants.MULTI_ADAPTER);

        _validateMultiAdapterConfiguration(multiAdapter, IntegrationConstants.BASE_CENTRIFUGE_ID);

        _validateMultiAdapterConfiguration(multiAdapter, IntegrationConstants.ARBITRUM_CENTRIFUGE_ID);

        _validateMultiAdapterConfiguration(multiAdapter, IntegrationConstants.PLUME_CENTRIFUGE_ID);

        _validateMultiAdapterConfiguration(multiAdapter, IntegrationConstants.AVALANCHE_CENTRIFUGE_ID);

        _validateMultiAdapterConfiguration(multiAdapter, IntegrationConstants.BNB_CENTRIFUGE_ID);
    }

    /// @notice Validates adapter source and destination mappings
    function _validateAdapterSourceDestinationMappings() internal view {
        WormholeAdapter wormholeAdapter = WormholeAdapter(IntegrationConstants.WORMHOLE_ADAPTER);
        AxelarAdapter axelarAdapter = AxelarAdapter(IntegrationConstants.AXELAR_ADAPTER);

        _validateWormholeMapping(
            wormholeAdapter, IntegrationConstants.BASE_WORMHOLE_ID, IntegrationConstants.BASE_CENTRIFUGE_ID, "Base"
        );

        _validateWormholeMapping(
            wormholeAdapter,
            IntegrationConstants.ARBITRUM_WORMHOLE_ID,
            IntegrationConstants.ARBITRUM_CENTRIFUGE_ID,
            "Arbitrum"
        );

        _validateWormholeMapping(
            wormholeAdapter, IntegrationConstants.PLUME_WORMHOLE_ID, IntegrationConstants.PLUME_CENTRIFUGE_ID, "Plume"
        );

        _validateWormholeMapping(
            wormholeAdapter,
            IntegrationConstants.AVALANCHE_WORMHOLE_ID,
            IntegrationConstants.AVALANCHE_CENTRIFUGE_ID,
            "Avalanche"
        );

        _validateWormholeMapping(
            wormholeAdapter, IntegrationConstants.BNB_WORMHOLE_ID, IntegrationConstants.BNB_CENTRIFUGE_ID, "BNB"
        );

        _validateAxelarMapping(
            axelarAdapter, IntegrationConstants.BASE_AXELAR_ID, IntegrationConstants.BASE_CENTRIFUGE_ID, "Base"
        );

        _validateAxelarMapping(
            axelarAdapter,
            IntegrationConstants.ARBITRUM_AXELAR_ID,
            IntegrationConstants.ARBITRUM_CENTRIFUGE_ID,
            "Arbitrum"
        );

        _validateAxelarMapping(
            axelarAdapter,
            IntegrationConstants.AVALANCHE_AXELAR_ID,
            IntegrationConstants.AVALANCHE_CENTRIFUGE_ID,
            "Avalanche"
        );

        _validateAxelarMapping(
            axelarAdapter, IntegrationConstants.BNB_AXELAR_ID, IntegrationConstants.BNB_CENTRIFUGE_ID, "BNB"
        );
    }

    /// @notice Helper function to validate MultiAdapter configuration for a specific chain
    function _validateMultiAdapterConfiguration(MultiAdapter multiAdapter, uint16 centrifugeId) internal view {
        // NOTE: Plume only has Wormhole
        bool hasAxelar = centrifugeId != IntegrationConstants.PLUME_CENTRIFUGE_ID;
        uint8 expectedQuorum = hasAxelar ? 2 : 1;

        uint8 actualQuorum = multiAdapter.quorum(centrifugeId);
        assertEq(actualQuorum, expectedQuorum);

        IAdapter primaryAdapter = multiAdapter.adapters(centrifugeId, 0);
        assertEq(address(primaryAdapter), IntegrationConstants.WORMHOLE_ADAPTER);

        if (hasAxelar) {
            IAdapter secondaryAdapter = multiAdapter.adapters(centrifugeId, 1);
            assertEq(address(secondaryAdapter), IntegrationConstants.AXELAR_ADAPTER);
        }
    }

    /// @notice Helper function to validate Wormhole adapter source/destination mappings
    function _validateWormholeMapping(
        WormholeAdapter wormholeAdapter,
        uint16 wormholeId,
        uint16 centrifugeId,
        string memory chainName
    ) internal view {
        // Validate source mapping (incoming from remote chain)
        (uint16 sourceCentrifugeId, address sourceAddr) = wormholeAdapter.sources(wormholeId);
        assertEq(
            sourceCentrifugeId,
            centrifugeId,
            string(abi.encodePacked("WormholeAdapter source centrifugeId mismatch for ", chainName))
        );
        assertEq(
            sourceAddr,
            IntegrationConstants.WORMHOLE_ADAPTER,
            string(abi.encodePacked("WormholeAdapter source address mismatch for ", chainName))
        );

        // Validate destination mapping (outgoing to remote chain)
        (uint16 destWormholeId, address destAddr) = wormholeAdapter.destinations(centrifugeId);
        assertEq(
            destWormholeId,
            wormholeId,
            string(abi.encodePacked("WormholeAdapter destination wormholeId mismatch for ", chainName))
        );
        assertEq(
            destAddr,
            IntegrationConstants.WORMHOLE_ADAPTER,
            string(abi.encodePacked("WormholeAdapter destination address mismatch for ", chainName))
        );
    }

    /// @notice Helper function to validate Axelar adapter source/destination mappings
    function _validateAxelarMapping(
        AxelarAdapter axelarAdapter,
        string memory axelarId,
        uint16 centrifugeId,
        string memory chainName
    ) internal view {
        // Validate source mapping (incoming from remote chain)
        (uint16 sourceCentrifugeId, bytes32 sourceAddressHash) = axelarAdapter.sources(axelarId);
        assertEq(
            sourceCentrifugeId,
            centrifugeId,
            string(abi.encodePacked("AxelarAdapter source centrifugeId mismatch for ", chainName))
        );
        // Note: addressHash is keccak256 of the remote adapter address string
        bytes32 expectedAddressHash = keccak256(abi.encodePacked(vm.toString(IntegrationConstants.AXELAR_ADAPTER)));
        assertEq(
            sourceAddressHash,
            expectedAddressHash,
            string(abi.encodePacked("AxelarAdapter source addressHash mismatch for ", chainName))
        );

        // Validate destination mapping (outgoing to remote chain)
        (string memory destAxelarId, string memory destAddr) = axelarAdapter.destinations(centrifugeId);
        assertEq(
            keccak256(bytes(destAxelarId)),
            keccak256(bytes(axelarId)),
            string(abi.encodePacked("AxelarAdapter destination axelarId mismatch for ", chainName))
        );
        assertEq(
            keccak256(bytes(destAddr)),
            keccak256(abi.encodePacked(vm.toString(IntegrationConstants.AXELAR_ADAPTER))),
            string(abi.encodePacked("AxelarAdapter destination address mismatch for ", chainName))
        );
    }

    function _validateWard(address wardedContract, address wardHolder) internal view {
        assertEq(IAuth(wardedContract).wards(wardHolder), 1);
    }
}
