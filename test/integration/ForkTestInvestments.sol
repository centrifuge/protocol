// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";
import {IntegrationConstants} from "./IntegrationConstants.sol";

import {ERC20} from "../../src/misc/ERC20.sol";
import {D18} from "../../src/misc/types/D18.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {MockValuation} from "../common/mocks/MockValuation.sol";

import {Root} from "../../src/common/Root.sol";
import {Gateway} from "../../src/common/Gateway.sol";
import {Guardian} from "../../src/common/Guardian.sol";
import {GasService} from "../../src/common/GasService.sol";
import {PoolId, newPoolId} from "../../src/common/types/PoolId.sol";
import {ShareClassId} from "../../src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/common/types/AssetId.sol";
import {VaultUpdateKind} from "../../src/common/libraries/MessageLib.sol";

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

    address constant FORK_POOL_ADMIN = IntegrationConstants.ETH_DEFAULT_POOL_ADMIN;

    CHub forkHub;
    CSpoke forkSpoke;
    ShareClassId forkShareClassId;
    AssetId forkAssetId;

    function setUp() public virtual override {
        vm.createSelectFork(_getRpcEndpoint());
        _loadContractsFromJson();
        _setupForkConfiguration();
    }

    function _getRpcEndpoint() internal view virtual returns (string memory) {
        return IntegrationConstants.RPC_ETHEREUM;
    }

    function _loadContractsFromJson() internal {
        uint16 centrifugeId = 1;

        forkHub = CHub({
            centrifugeId: centrifugeId,
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
            centrifugeId: centrifugeId,
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
            usdcId: newAssetId(centrifugeId, 1)
        });

        // Initialize pricing state
        currentAssetPrice = IntegrationConstants.identityPrice();
        currentSharePrice = IntegrationConstants.identityPrice();

        // Fund pool admin
        vm.deal(FORK_POOL_ADMIN, 10 ether);
    }

    function _setupForkConfiguration() internal {
        // Set up pool and share class configuration for fork tests
        forkShareClassId = ShareClassId.wrap(bytes16(abi.encodePacked(uint128(1125899906842625))));
        forkAssetId = newAssetId(1, 1);

        // Initialize USD_ID for pricing utilities
        USD_ID = forkAssetId;
    }

    function _addPoolMember(IBaseVault vault, address user) internal virtual {
        vm.startPrank(FORK_POOL_ADMIN);
        forkHub.hub.updateRestriction{value: GAS}(
            vault.poolId(), vault.scId(), forkSpoke.centrifugeId, _updateRestrictionMemberMsg(user), EXTRA_GAS
        );
        vm.stopPrank();
    }

    /// @dev Override to skip mock valuation price setting in fork tests
    /// Fork tests use real IdentityValuation which doesn't support setPrice()
    function _baseConfigurePrices(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager,
        D18 assetPrice,
        D18 sharePrice
    ) internal override {
        // Fork tests use address(0) for valuation, so skip the setPrice() call
        // But we still need to set the share price for the pool
        currentAssetPrice = assetPrice;
        currentSharePrice = sharePrice;

        vm.startPrank(poolManager);
        hub.hub.updateSharePrice(poolId, shareClassId, sharePrice);
        vm.stopPrank();
    }
}

contract ForkTestAsyncInvestments is ForkTestBase {
    // TODO: After v2 disable, switch to JAAA
    address public constant VAULT = IntegrationConstants.ETH_DEJAAA_VAULT;

    uint128 constant depositAmount = IntegrationConstants.DEFAULT_USDC_AMOUNT;

    function test_completeAsyncDepositFlow() public {
        _completeAsyncDeposit(VAULT, makeAddr("INVESTOR_A"), depositAmount);
    }

    function test_completeAsyncRedeemFlow() public {
        _completeAsyncRedeem(VAULT, makeAddr("INVESTOR_A"), depositAmount);
    }

    function _completeAsyncDeposit(address vault_, address investor, uint128 amount) internal {
        IBaseVault vault = IBaseVault(vault_);

        deal(vault.asset(), investor, amount);
        _addPoolMember(vault, investor);

        _asyncDepositFlow(
            forkHub,
            forkSpoke,
            vault.poolId(),
            vault.scId(),
            forkSpoke.spoke.assetToId(vault.asset(), 0),
            IntegrationConstants.ETH_DEFAULT_POOL_ADMIN,
            investor,
            amount,
            true,
            true,
            vault_
        );
    }

    function _completeAsyncRedeem(address vault_, address investor, uint128 amount) internal {
        _completeAsyncDeposit(vault_, investor, amount);

        IBaseVault vault = IBaseVault(vault_);

        _syncRedeemFlow(
            forkHub,
            forkSpoke,
            vault.poolId(),
            vault.scId(),
            forkSpoke.spoke.assetToId(vault.asset(), 0),
            IntegrationConstants.ETH_DEFAULT_POOL_ADMIN,
            investor,
            true,
            true,
            vault_
        );
    }
}

contract ForkTestSyncInvestments is ForkTestBase {
    using CastLib for *;

    // We'll create a new pool and vault on Ethereum mainnet fork
    PoolId testPoolId;
    ShareClassId testShareClassId;
    AssetId testAssetId;
    address testSyncDepositVault;

    function setUp() public override {
        super.setUp();
        _createTestPoolAndVault();
    }

    function _createTestPoolAndVault() internal {
        uint48 randomPoolId = uint48(uint256(keccak256(abi.encode(block.timestamp, block.number))) % 1e14);
        testPoolId = newPoolId(1, randomPoolId);

        // Use the pre-existing USD_ID that's already registered in hub registry during deployment
        testAssetId = USD_ID; // USD_ID = newAssetId(840) is already registered with 18 decimals

        vm.startPrank(address(forkHub.guardian.safe()));
        forkHub.guardian.createPool(testPoolId, FORK_POOL_ADMIN, testAssetId);
        vm.stopPrank();

        // Set up the pool metadata and share class
        vm.startPrank(FORK_POOL_ADMIN);
        forkHub.hub.setPoolMetadata(testPoolId, bytes("Test Sync Pool"));
        testShareClassId = forkHub.shareClassManager.previewNextShareClassId(testPoolId);
        forkHub.hub.addShareClass(testPoolId, "Test Sync Shares", "TSS", bytes32("test_salt"));
        vm.stopPrank();

        _createPoolAccounts(forkHub, testPoolId, FORK_POOL_ADMIN);
        _subsidizePool(forkHub, testPoolId);

        AssetId spokeAssetId = forkSpoke.spoke.assetToId(address(forkSpoke.usdc), 0);

        // Configure pool cross-chain to create share token on spoke
        vm.startPrank(FORK_POOL_ADMIN);
        forkHub.hub.notifyPool{value: GAS}(testPoolId, forkSpoke.centrifugeId);
        forkHub.hub.notifyShareClass{value: GAS}(
            testPoolId,
            testShareClassId,
            forkSpoke.centrifugeId,
            address(forkSpoke.redemptionRestrictionsHook).toBytes32()
        );
        vm.stopPrank();

        // Deploy the sync deposit vault
        vm.startPrank(FORK_POOL_ADMIN);
        forkHub.hub.updateVault{value: GAS}(
            testPoolId,
            testShareClassId,
            spokeAssetId,
            forkSpoke.syncDepositVaultFactory,
            VaultUpdateKind.DeployAndLink,
            EXTRA_GAS
        );
        vm.stopPrank();

        testSyncDepositVault =
            address(forkSpoke.asyncRequestManager.vaultByAssetId(testPoolId, testShareClassId, spokeAssetId));

        // Update testAssetId to use the spoke-side asset ID for the tests
        testAssetId = spokeAssetId;
    }

    // Override _addPoolMember to use the correct pool admin for our test pool
    function _addPoolMember(IBaseVault vault, address user) internal override {
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        vm.startPrank(FORK_POOL_ADMIN);
        _updateRestrictionMemberMsg(user);
        vm.stopPrank();
    }

    // TODO: Re-enable when Plume mainnet has sync deposit vault deployed
    // Currently disabled due to authorization issues with custom test pool setup
    // Will use real Plume mainnet pool instead of creating test pools
    /*
    function test_completeSyncDepositFlow() public {
        _completeSyncDeposit(testSyncDepositVault, makeAddr("INVESTOR_A"), 1e3); // 0.001 USDC
    }

    function test_completeSyncDepositAsyncRedeemFlow() public {
        _completeAsyncRedeem(testSyncDepositVault, makeAddr("INVESTOR_A"), 1e6);
    }
    */

    function _completeSyncDeposit(address vault_, address investor, uint128 amount) internal {
        IBaseVault vault = IBaseVault(vault_);

        _addPoolMember(vault, investor);

        deal(address(forkSpoke.usdc), investor, amount);
        _syncDepositFlow(
            forkHub, forkSpoke, testPoolId, testShareClassId, testAssetId, FORK_POOL_ADMIN, investor, amount, true, true
        );
    }

    function _completeAsyncRedeem(address vault_, address investor, uint128 amount) internal {
        _completeSyncDeposit(vault_, investor, amount);

        _syncRedeemFlow(
            forkHub,
            forkSpoke,
            testPoolId,
            testShareClassId,
            testAssetId,
            FORK_POOL_ADMIN,
            investor,
            true,
            true,
            address(0)
        );
    }
}
