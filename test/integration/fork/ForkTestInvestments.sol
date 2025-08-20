// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ForkTestBase} from "./ForkTestBase.sol";

import {ERC20} from "../../../src/misc/ERC20.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {MockValuation} from "../../common/mocks/MockValuation.sol";

import {Root} from "../../../src/common/Root.sol";
import {Gateway} from "../../../src/common/Gateway.sol";
import {Guardian} from "../../../src/common/Guardian.sol";
import {GasService} from "../../../src/common/GasService.sol";

import {Hub} from "../../../src/hub/Hub.sol";
import {Holdings} from "../../../src/hub/Holdings.sol";
import {Accounting} from "../../../src/hub/Accounting.sol";
import {HubRegistry} from "../../../src/hub/HubRegistry.sol";
import {ShareClassManager} from "../../../src/hub/ShareClassManager.sol";

import {Spoke} from "../../../src/spoke/Spoke.sol";
import {BalanceSheet} from "../../../src/spoke/BalanceSheet.sol";

import {SyncManager} from "../../../src/vaults/SyncManager.sol";
import {VaultRouter} from "../../../src/vaults/VaultRouter.sol";
import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {AsyncRequestManager} from "../../../src/vaults/AsyncRequestManager.sol";

import {MockSnapshotHook} from "../../hooks/mocks/MockSnapshotHook.sol";

import {FreezeOnly} from "../../../src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "../../../src/hooks/FullRestrictions.sol";
import {RedemptionRestrictions} from "../../../src/hooks/RedemptionRestrictions.sol";

import {IdentityValuation} from "../../../src/valuations/IdentityValuation.sol";

import "forge-std/Test.sol";

import {VMLabeling} from "../utils/VMLabeling.sol";
import {IntegrationConstants} from "../utils/IntegrationConstants.sol";

/// @title ForkTestAsyncInvestments
/// @notice Fork tests for async investment flows on Ethereum mainnet
contract ForkTestAsyncInvestments is ForkTestBase, VMLabeling {
    // TODO(later): After v2 disable, switch to JAAA
    IBaseVault constant VAULT = IBaseVault(IntegrationConstants.ETH_DEJAA_USDC_VAULT);

    uint128 constant depositAmount = IntegrationConstants.DEFAULT_USDC_AMOUNT;

    function setUp() public virtual override {
        super.setUp();
        _setupVMLabels();
    }

    function test_completeAsyncDepositFlow() public virtual {
        _completeAsyncDeposit(VAULT, makeAddr("INVESTOR_A"), depositAmount);
    }

    function test_completeAsyncRedeemFlow() public virtual {
        _completeAsyncRedeem(VAULT, makeAddr("INVESTOR_A"), depositAmount);
    }

    function _completeAsyncDeposit(IBaseVault vault, address investor, uint128 amount) internal {
        if (isShareToken(vault.asset())) {
            vm.startPrank(IntegrationConstants.V2_ROOT);
            ERC20(vault.asset()).mint(investor, amount);
            vm.stopPrank();
        } else {
            // NOTE: Does not work for share tokens: [Revert] panic: arithmetic underflow or overflow (0x11)
            deal(vault.asset(), investor, amount, true);
        }
        _addPoolMember(vault, investor);

        _asyncDepositFlow(
            forkHub,
            forkSpoke,
            vault.poolId(),
            vault.scId(),
            forkSpoke.spoke.assetToId(vault.asset(), 0),
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

        _asyncRedeemFlow(
            forkHub,
            forkSpoke,
            vault.poolId(),
            vault.scId(),
            forkSpoke.spoke.assetToId(vault.asset(), 0),
            _poolAdmin(),
            investor,
            true,
            true,
            address(vault)
        );
    }
}

/// @title ForkTestSyncInvestments
/// @notice Fork tests for sync investment flows on Plume network
contract ForkTestSyncInvestments is ForkTestBase, VMLabeling {
    using CastLib for *;

    IBaseVault constant VAULT = IBaseVault(IntegrationConstants.PLUME_SYNC_DEPOSIT_VAULT);

    function setUp() public override {
        vm.createSelectFork(IntegrationConstants.RPC_PLUME);

        _loadContracts();
        _setupVMLabels();

        _baseConfigurePrices(
            forkHub,
            forkSpoke,
            VAULT.poolId(),
            VAULT.scId(),
            forkSpoke.spoke.assetToId(VAULT.asset(), 0),
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
        // _completeSyncDeposit(makeAddr("INVESTOR_A"), 1000e18);
    }

    function test_completeSyncDepositAsyncRedeemFlow() public {
        // _completeSyncDepositAsyncRedeem(makeAddr("INVESTOR_A"), 1000e18);
    }

    function _completeSyncDeposit(address investor, uint128 amount) internal {
        _addPoolMember(VAULT, investor);

        deal(VAULT.asset(), investor, amount);
        _syncDepositFlow(
            forkHub,
            forkSpoke,
            VAULT.poolId(),
            VAULT.scId(),
            forkSpoke.spoke.assetToId(VAULT.asset(), 0),
            _poolAdmin(),
            investor,
            amount,
            true,
            true
        );
    }

    function _completeSyncDepositAsyncRedeem(address investor, uint128 amount) internal {
        _completeSyncDeposit(investor, amount);

        _asyncRedeemFlow(
            forkHub,
            forkSpoke,
            VAULT.poolId(),
            VAULT.scId(),
            forkSpoke.spoke.assetToId(VAULT.asset(), 0),
            _poolAdmin(),
            investor,
            true,
            true,
            address(VAULT)
        );
    }
}
