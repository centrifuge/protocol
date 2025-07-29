// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../src/misc/types/D18.sol";
import {IERC20} from "../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";
import {IEscrow} from "../../src/misc/interfaces/IEscrow.sol";

import {PoolId} from "../../src/common/types/PoolId.sol";
import {AssetId} from "../../src/common/types/AssetId.sol";
import {IRoot} from "../../src/common/interfaces/IRoot.sol";
import {ShareClassId} from "../../src/common/types/ShareClassId.sol";
import {ISpokeGatewayHandler} from "../../src/common/interfaces/IGatewayHandlers.sol";

import {IHub} from "../../src/hub/interfaces/IHub.sol";
import {IHubRegistry} from "../../src/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "../../src/hub/interfaces/IShareClassManager.sol";

import {ISpoke} from "../../src/spoke/interfaces/ISpoke.sol";
import {VaultKind} from "../../src/spoke/interfaces/IVault.sol";
import {IShareToken} from "../../src/spoke/interfaces/IShareToken.sol";
import {IBalanceSheet} from "../../src/spoke/interfaces/IBalanceSheet.sol";
import {UpdateContractMessageLib} from "../../src/spoke/libraries/UpdateContractMessageLib.sol";

import {SyncManager} from "../../src/vaults/SyncManager.sol";
import {IBaseVault} from "../../src/vaults/interfaces/IBaseVault.sol";
import {IAsyncRequestManager} from "../../src/vaults/interfaces/IVaultManagers.sol";
import {IAsyncVault, IAsyncRedeemVault} from "../../src/vaults/interfaces/IAsyncVault.sol";

import {UpdateRestrictionMessageLib} from "../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import "forge-std/Test.sol";

contract ForkTestBase is Test {
    // V3 contracts from env/ethereum.json
    IRoot public constant ROOT = IRoot(0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f);
    ISpoke public constant SPOKE = ISpoke(0xd30Da1d7F964E5f6C2D9fE2AAA97517F6B23FA2B);
    IHub public constant HUB = IHub(0x9c8454A506263549f07c80698E276e3622077098);
    IHubRegistry public constant HUB_REGISTRY = IHubRegistry(0x12044ef361Cc3446Cb7d36541C8411EE4e6f52cb);
    IShareClassManager public constant SCM = IShareClassManager(0xe88e712d60bfd23048Dbc677FEb44E2145F2cDf4);
    SyncManager public constant SYNC_MANAGER = SyncManager(0x0D82d9fa76CFCd6F4cc59F053b2458665C6CE773);
    IBalanceSheet public constant BALANCE_SHEET = IBalanceSheet(0xBcC8D02d409e439D98453C0b1ffa398dFFb31fda);
    IEscrow public constant GLOBAL_ESCROW = IEscrow(0x43d51be0B6dE2199A2396bA604114d24383F91E9);

    // V3.0.0 contracts (before spell is applied)
    IAsyncRequestManager public constant newAsyncRequestManager =
        IAsyncRequestManager(0x58d57896EBbF000c293327ADf33689D0a7Fd3d9A);
    address public constant ASYNC_VAULT_FACTORY = 0xE01Ce2e604CCe985A06FA4F4bCD17f1F08417BF3;
    address public constant SYNC_DEPOSIT_VAULT_FACTORY = 0x3568184784E8ACCaacF51A7F710a3DE0144E4f29;

    function setUp() public virtual {
        vm.createSelectFork(_getRpcEndpoint());
    }

    function _getRpcEndpoint() internal view virtual returns (string memory) {
        return "https://ethereum-rpc.publicnode.com";
    }

    // Default Ethereum pool poolAdmin
    function _getPoolAdmin() internal pure virtual returns (address) {
        return address(0x742d100011fFbC6e509E39DbcB0334159e86be1e);
    }
}

contract ForkTestInvestmentHelpers is ForkTestBase {
    using CastLib for *;
    using UpdateContractMessageLib for *;

    uint128 constant depositAmount = 1e12;

    //----------------------------------------------------------------------------------------------
    // Pool Member Management Helpers
    //----------------------------------------------------------------------------------------------

    function _addPoolMember(IBaseVault vault, address user) internal {
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        UpdateRestrictionMessageLib.UpdateRestrictionMember memory memberUpdate = UpdateRestrictionMessageLib
            .UpdateRestrictionMember({user: bytes32(bytes20(user)), validUntil: type(uint64).max});
        bytes memory payload = UpdateRestrictionMessageLib.serialize(memberUpdate);

        // Short cut message from hub by temporarily adding this test as spoke ward
        bytes32 spokeWardSlot = keccak256(abi.encode(address(this), uint256(0)));
        vm.store(address(SPOKE), spokeWardSlot, bytes32(uint256(1)));
        ISpokeGatewayHandler(address(SPOKE)).updateRestriction(poolId, scId, payload);

        // Remove temporary spoke ward
        vm.store(address(SPOKE), spokeWardSlot, bytes32(uint256(0)));
    }

    function _addRestrictionMember(PoolId poolId, ShareClassId scId, address user) internal {
        UpdateRestrictionMessageLib.UpdateRestrictionMember memory memberUpdate = UpdateRestrictionMessageLib
            .UpdateRestrictionMember({user: bytes32(bytes20(user)), validUntil: type(uint64).max});
        bytes memory payload = UpdateRestrictionMessageLib.serialize(memberUpdate);

        // Short cut message from hub by temporarily adding this test as spoke ward
        bytes32 spokeWardSlot = keccak256(abi.encode(address(this), uint256(0)));
        vm.store(address(SPOKE), spokeWardSlot, bytes32(uint256(1)));
        ISpokeGatewayHandler(address(SPOKE)).updateRestriction(poolId, scId, payload);

        // Remove temporary spoke ward
        vm.store(address(SPOKE), spokeWardSlot, bytes32(uint256(0)));
    }

    //----------------------------------------------------------------------------------------------
    // Deposit Flow Helpers
    //----------------------------------------------------------------------------------------------

    function _poolAdminApproveDeposits(IAsyncVault vault, uint128 amount) internal {
        PoolId poolId = vault.poolId();
        AssetId assetId = SPOKE.assetToId(vault.asset(), 0);

        // Use appropriate pool poolAdmin based on vault
        address poolAdmin = _getPoolAdmin();
        bool isManager = HUB_REGISTRY.manager(poolId, poolAdmin);
        assertTrue(isManager, "Pool admin should have manager permissions");

        vm.startPrank(poolAdmin);
        vm.deal(poolAdmin, 1 ether);

        uint32 epochId = SCM.nowDepositEpoch(vault.scId(), assetId);
        HUB.approveDeposits{value: 0.1 ether}(poolId, vault.scId(), assetId, epochId, amount);

        vm.stopPrank();
    }

    function _poolAdminIssueShares(IAsyncVault vault) internal {
        PoolId poolId = vault.poolId();
        AssetId assetId = SPOKE.assetToId(vault.asset(), 0);
        ShareClassId scId = vault.scId();

        address poolAdmin = _getPoolAdmin();
        vm.startPrank(poolAdmin);
        vm.deal(poolAdmin, 1 ether);

        uint32 issueEpochId = SCM.nowIssueEpoch(scId, assetId);
        D18 sharePrice = D18.wrap(1e18);

        (uint128 issuedShares,,) =
            HUB.issueShares{value: 0.1 ether}(poolId, scId, assetId, issueEpochId, sharePrice, 50000); // 50k gas for hook
        assertGt(issuedShares, 0, "No shares issued");

        vm.stopPrank();
    }

    function _notifyDepositCompletion(IAsyncVault vault, address investor) internal {
        PoolId poolId = vault.poolId();
        AssetId assetId = SPOKE.assetToId(vault.asset(), 0);
        ShareClassId scId = vault.scId();

        address anyCaller = makeAddr("ANY_CALLER");
        vm.deal(anyCaller, 1 ether);

        uint32 maxClaims = SCM.maxDepositClaims(scId, investor.toBytes32(), assetId);
        vm.startPrank(anyCaller);
        HUB.notifyDeposit{value: 0.1 ether}(poolId, scId, assetId, investor.toBytes32(), maxClaims);
        vm.stopPrank();
    }

    //----------------------------------------------------------------------------------------------
    // Redeem Flow Helpers
    //----------------------------------------------------------------------------------------------

    function _poolAdminApproveRedeems(IAsyncRedeemVault vault, uint128 shares) internal {
        PoolId poolId = vault.poolId();
        AssetId assetId = SPOKE.assetToId(vault.asset(), 0);

        address poolAdmin = _getPoolAdmin();
        bool isManager = HUB_REGISTRY.manager(poolId, poolAdmin);
        assertTrue(isManager, "Pool admin should have manager permissions");

        vm.startPrank(poolAdmin);
        vm.deal(poolAdmin, 1 ether);

        uint32 epochId = SCM.nowRedeemEpoch(vault.scId(), assetId);
        HUB.approveRedeems(poolId, vault.scId(), assetId, epochId, shares);

        vm.stopPrank();
    }

    function _poolAdminRevokeShares(IAsyncRedeemVault vault) internal {
        PoolId poolId = vault.poolId();
        AssetId assetId = SPOKE.assetToId(vault.asset(), 0);
        ShareClassId scId = vault.scId();

        address poolAdmin = _getPoolAdmin();
        vm.startPrank(poolAdmin);
        vm.deal(poolAdmin, 1 ether);

        uint32 revokeEpochId = SCM.nowRevokeEpoch(scId, assetId);
        D18 sharePrice = D18.wrap(1e18);

        (uint128 revokedAssets,,) =
            HUB.revokeShares{value: 0.1 ether}(poolId, scId, assetId, revokeEpochId, sharePrice, 50000); // 50k gas for hook
        assertGt(revokedAssets, 0, "No assets revoked");

        vm.stopPrank();
    }

    function _notifyRedeemCompletion(IAsyncRedeemVault vault, address investor) internal {
        PoolId poolId = vault.poolId();
        AssetId assetId = SPOKE.assetToId(vault.asset(), 0);
        ShareClassId scId = vault.scId();

        address anyCaller = makeAddr("ANY_CALLER");
        vm.deal(anyCaller, 1 ether);

        uint32 maxClaims = SCM.maxRedeemClaims(scId, investor.toBytes32(), assetId);
        vm.startPrank(anyCaller);
        HUB.notifyRedeem{value: 0.1 ether}(poolId, scId, assetId, investor.toBytes32(), maxClaims);
        vm.stopPrank();
    }

    //----------------------------------------------------------------------------------------------
    // Sync Deposit Flow Helpers
    //----------------------------------------------------------------------------------------------

    function _setSyncDepositMaxReserve(IBaseVault vault, uint128 maxReserve) internal {
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        // Shortcut: directly call SyncManager.setMaxReserve instead of going through Hub.updateContract on vault
        bytes32 wardSlot = keccak256(abi.encode(address(this), uint256(0)));
        vm.store(address(SYNC_MANAGER), wardSlot, bytes32(uint256(1)));
        SYNC_MANAGER.setMaxReserve(poolId, scId, vault.asset(), 0, maxReserve);
        vm.store(address(SYNC_MANAGER), wardSlot, bytes32(uint256(0)));
    }

    function _configurePricesForSyncDeposit(IBaseVault vault) internal {
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = SPOKE.assetToId(vault.asset(), 0);

        // Use identity prices for simplicity
        D18 pricePoolPerShare = d18(1, 1);

        address poolAdmin = _getPoolAdmin();
        uint16 centrifugeId = _getCentrifugeId(address(vault));

        _configurePrices(poolId, scId, assetId, pricePoolPerShare, poolAdmin, centrifugeId);
    }

    function _configurePrices(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        D18 pricePoolPerShare,
        address poolAdmin,
        uint16 centrifugeId
    ) internal {
        vm.deal(poolAdmin, 1 ether);

        vm.startPrank(poolAdmin);
        HUB.updateSharePrice{value: 0.1 ether}(poolId, scId, pricePoolPerShare);
        HUB.notifyAssetPrice{value: 0.1 ether}(poolId, scId, assetId);
        HUB.notifySharePrice{value: 0.1 ether}(poolId, scId, centrifugeId);
        vm.stopPrank();
    }

    function _getCentrifugeId(address vault) internal pure returns (uint16) {
        if (vault == 0x374Bc3D556fBc9feC0b9537c259DCB7935f7E5bf) {
            return 4;
        }
        return 1;
    }

    function _isAsyncVault(address vault) internal view returns (bool) {
        VaultKind kind = IBaseVault(vault).vaultKind();
        return kind == VaultKind.Async;
    }

    function _isSyncDepositVault(address vault) internal view returns (bool) {
        VaultKind kind = IBaseVault(vault).vaultKind();
        return kind == VaultKind.SyncDepositAsyncRedeem;
    }

    //----------------------------------------------------------------------------------------------
    // Complete Deposit Flows
    //----------------------------------------------------------------------------------------------

    function _completeDeposit(address vault_, address investor, uint128 amount) internal {
        IBaseVault vault = IBaseVault(vault_);
        IShareToken shareToken = SPOKE.shareToken(vault.poolId(), vault.scId());

        // Common setup for all vault types
        deal(vault.asset(), investor, amount);
        _addPoolMember(vault, investor);

        if (_isAsyncVault(vault_)) {
            IAsyncVault asyncVault = IAsyncVault(vault_);

            vm.startPrank(investor);
            IERC20(asyncVault.asset()).approve(address(asyncVault), amount);
            asyncVault.requestDeposit(amount, investor, investor);
            vm.stopPrank();

            _poolAdminApproveDeposits(asyncVault, amount);
            _poolAdminIssueShares(asyncVault);
            _notifyDepositCompletion(asyncVault, investor);

            // mint shares
            uint256 sharesBefore = shareToken.balanceOf(investor);

            vm.startPrank(investor);
            uint256 maxMintable = vault.maxMint(investor);
            assertGt(maxMintable, 0, "Max mintable shares should be greater than 0");
            vault.mint(maxMintable, investor);
            vm.stopPrank();

            uint256 sharesAfter = shareToken.balanceOf(investor);
            assertGt(sharesAfter, sharesBefore, "User should have received shares");
        } else if (_isSyncDepositVault(vault_)) {
            _configurePricesForSyncDeposit(vault);
            _setSyncDepositMaxReserve(vault, type(uint128).max);

            // mint shares
            uint256 sharesBefore = shareToken.balanceOf(investor);

            vm.startPrank(investor);
            IERC20(vault.asset()).approve(vault_, amount);
            vault.deposit(amount, investor);
            vm.stopPrank();

            uint256 sharesAfter = shareToken.balanceOf(investor);
            assertGt(sharesAfter, sharesBefore, "User should have received shares");
        } else {
            revert("Unsupported vault type");
        }
    }

    // Backward compatibility wrapper for existing tests that use hardcoded VAULT_1
    function _completeAsyncDeposit(address vault, address investor, uint128 amount) internal {
        _completeDeposit(vault, investor, amount);
    }

    // Wrapper for sync deposit tests
    function _completeSyncDeposit(address vault, address investor, uint128 amount) internal {
        _completeDeposit(vault, investor, amount);
    }

    //----------------------------------------------------------------------------------------------
    // Complete Async RedeemFlow
    //----------------------------------------------------------------------------------------------

    function _completeAsyncRedeem(address vaultAddress, address investor, uint128 amount) internal {
        // First, complete an initial deposit to have shares to redeem
        _completeDeposit(vaultAddress, investor, amount);

        IAsyncRedeemVault vault = IAsyncRedeemVault(vaultAddress);
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        IShareToken shareToken = SPOKE.shareToken(poolId, scId);

        uint128 sharesToRedeem = uint128(shareToken.balanceOf(investor));
        assertGt(sharesToRedeem, 0, "Should have shares to redeem");

        // Add investor to restriction list for redemption
        _addRestrictionMember(poolId, scId, investor);

        // Request redeem
        vm.startPrank(investor);
        vault.requestRedeem(sharesToRedeem, investor, investor);
        vm.stopPrank();

        assertEq(
            newAsyncRequestManager.pendingRedeemRequest(IBaseVault(address(vault)), investor),
            sharesToRedeem,
            "Redeem request not recorded with new manager"
        );

        _poolAdminApproveRedeems(vault, sharesToRedeem);

        _poolAdminRevokeShares(vault);

        _notifyRedeemCompletion(vault, investor);

        // Withdraw assets
        uint256 assetsBefore = IERC20(vault.asset()).balanceOf(investor);
        vm.startPrank(investor);
        uint256 maxWithdrawable = vault.maxWithdraw(investor);
        assertGt(maxWithdrawable, 0, "Max withdrawable assets should be greater than 0");
        vault.withdraw(maxWithdrawable, investor, investor);
        vm.stopPrank();

        uint256 assetsAfter = IERC20(vault.asset()).balanceOf(investor);
        assertGt(assetsAfter, assetsBefore, "User should have received assets");
    }
}

contract ForkTestAsyncInvestments is ForkTestInvestmentHelpers {
    // JAAA (Avalanche) & deJAAA (Ethereum) USD vaults
    address public constant VAULT_1 = 0x1121F4e21eD8B9BC1BB9A2952cDD8639aC897784;

    function test_completeAsyncDepositFlow() public {
        _completeAsyncDeposit(VAULT_1, makeAddr("INVESTOR_A"), depositAmount);
    }

    function test_completeAsyncRedeemFlow() public {
        _completeAsyncRedeem(VAULT_1, makeAddr("INVESTOR_A"), depositAmount);
    }
}

contract ForkTestSyncInvestments is ForkTestInvestmentHelpers {
    PoolId public constant PLUME_POOL_ID = PoolId.wrap(1125899906842625);
    address public constant PLUME_POOL_ADMIN = 0xB3B442BFee81F9c2bE2c146A823cB54a2625DF98;
    address public constant PLUME_SYNC_DEPOSIT_VAULT = 0x374Bc3D556fBc9feC0b9537c259DCB7935f7E5bf;

    function _getRpcEndpoint() internal pure override returns (string memory) {
        return "wss://rpc.plume.org";
    }

    function _getPoolAdmin() internal pure override returns (address) {
        return 0xB3B442BFee81F9c2bE2c146A823cB54a2625DF98;
    }

    function test_completeSyncDepositFlow() public {
        _completeSyncDeposit(address(PLUME_SYNC_DEPOSIT_VAULT), makeAddr("INVESTOR_A"), 1e6);
    }

    function test_completeSyncDepositAsyncRedeemFlow() public {
        _completeAsyncRedeem(PLUME_SYNC_DEPOSIT_VAULT, makeAddr("INVESTOR_A"), 1e6);
    }
}
