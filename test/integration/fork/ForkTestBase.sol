// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "../../../src/misc/ERC20.sol";
import {D18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {Root} from "../../../src/common/Root.sol";
import {Gateway} from "../../../src/common/Gateway.sol";
import {Guardian} from "../../../src/common/Guardian.sol";
import {PoolId} from "../../../src/common/types/PoolId.sol";
import {GasService} from "../../../src/common/GasService.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../src/common/types/AssetId.sol";

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

import {OracleValuation} from "../../../src/valuations/OracleValuation.sol";
import {IdentityValuation} from "../../../src/valuations/IdentityValuation.sol";

import {NAVManager} from "../../../src/managers/NAVManager.sol";
import {SimplePriceManager} from "../../../src/managers/SimplePriceManager.sol";

import "forge-std/Test.sol";

import {EndToEndFlows} from "../EndToEnd.t.sol";
import {IntegrationConstants} from "../utils/IntegrationConstants.sol";

/// @title ForkTestBase
/// @notice Base contract for all fork tests, providing common setup and utilities
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

    function _poolAdmin() internal view virtual returns (address) {
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
            oracleValuation: OracleValuation(address(0)), // TODO: add this once deployed
            navManager: NAVManager(address(0)), // Fork tests don't use snapshot hooks
            priceManager: SimplePriceManager(payable(0)) // Fork tests doesn't use priceManager
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
            usdc: ERC20(address(0)), // NOTE: Unused in fork tests in order to be chain agnostic
            usdcId: newAssetId(0) // NOTE: Unused in fork tests in order to be chain agnostic
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
