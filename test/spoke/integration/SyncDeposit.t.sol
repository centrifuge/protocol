// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/spoke/BaseTest.sol";

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7751} from "src/misc/interfaces/IERC7751.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {ITransferHook} from "src/common/interfaces/ITransferHook.sol";
import {IBalanceSheet} from "src/spoke/interfaces/IBalanceSheet.sol";
import {SyncDepositVault} from "src/vaults/SyncDepositVault.sol";
import {VaultDetails} from "src/spoke/interfaces/ISpoke.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {IBaseRequestManager} from "src/vaults/interfaces/IBaseRequestManager.sol";
import {IAsyncRedeemVault} from "src/vaults/interfaces/IAsyncVault.sol";
import {IVault} from "src/spoke/interfaces/IVaultManager.sol";

contract SyncDepositTestHelper is BaseTest {
    using CastLib for *;
    using MessageLib for *;
    using MathLib for *;

    function _deploySyncDepositVault(D18 pricePoolPerShare, D18 pricePoolPerAsset)
        internal
        returns (SyncDepositVault syncVault, uint128 assetId)
    {
        (, address syncVault_, uint128 assetId_) = deploySimpleVault(VaultKind.SyncDepositAsyncRedeem);
        assetId = assetId_;
        syncVault = SyncDepositVault(syncVault_);

        centrifugeChain.updatePricePoolPerShare(
            syncVault.poolId().raw(), syncVault.scId().raw(), pricePoolPerShare.inner(), uint64(block.timestamp)
        );
        centrifugeChain.updatePricePoolPerAsset(
            syncVault.poolId().raw(),
            syncVault.scId().raw(),
            assetId,
            pricePoolPerAsset.inner(),
            uint64(block.timestamp)
        );
    }

    function _assertDepositEvents(SyncDepositVault vault, uint128 shares, D18 pricePoolPerShare, D18 pricePoolPerAsset)
        internal
    {
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        uint128 depositAssetAmount = vault.previewMint(shares).toUint128();
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault);

        vm.expectEmit();
        emit IBalanceSheet.Issue(poolId, scId, self, pricePoolPerShare, shares);

        vm.expectEmit();
        emit IBalanceSheet.NoteDeposit(
            poolId, scId, vault.asset(), vaultDetails.tokenId, depositAssetAmount, pricePoolPerAsset
        );
    }
}

contract SyncDepositTest is SyncDepositTestHelper {
    using CastLib for *;
    using MessageLib for *;
    using MathLib for *;

    uint128 assetsPerShare = 2;
    D18 priceAssetPerShare = d18(assetsPerShare, 1);
    D18 pricePoolPerShare = d18(4, 1);
    D18 pricePoolPerAsset = pricePoolPerShare / priceAssetPerShare;

    function testFile(bytes32 fileTarget, address nonWard) public {
        vm.assume(fileTarget != "manager" && fileTarget != "asyncRedeemManager" && fileTarget != "syncDepositManager");
        vm.assume(
            nonWard != address(root) && nonWard != address(this) && nonWard != address(syncRequestManager)
                && nonWard != address(asyncRequestManager)
        );
        address random = makeAddr("random");
        (SyncDepositVault vault,) = _deploySyncDepositVault(d18(0), d18(0));

        vm.startPrank(address(root));

        vm.expectEmit();
        emit IBaseVault.File("manager", random);
        vault.file("manager", random);
        assertEq(address(vault.manager()), random);

        vm.expectEmit();
        emit IBaseVault.File("syncDepositManager", random);
        vault.file("syncDepositManager", random);
        assertEq(address(vault.syncDepositManager()), random);

        vm.expectEmit();
        emit IBaseVault.File("asyncRedeemManager", random);
        vault.file("asyncRedeemManager", random);
        assertEq(address(vault.asyncRedeemManager()), random);

        vm.expectRevert(IBaseVault.FileUnrecognizedParam.selector);
        vault.file(fileTarget, random);

        vm.stopPrank();
        vm.prank(random);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vault.file("manager", random);
    }

    /// forge-config: default.isolate = true
    function testSyncDepositERC20() public {
        _testSyncDepositERC20(4, true);
    }

    /// forge-config: default.isolate = true
    function testSyncDepositERC20Fuzz(uint256 amount) public {
        vm.assume(amount % 2 == 0);
        _testSyncDepositERC20(amount, false);
    }

    function _testSyncDepositERC20(uint256 amount, bool snap) internal {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128 / assetsPerShare));
        vm.assume(amount % 2 == 0);

        // Fund such that we can deposit
        erc20.mint(self, amount);

        // Deploy sync vault
        (SyncDepositVault syncVault, uint128 assetId) = _deploySyncDepositVault(pricePoolPerShare, pricePoolPerAsset);
        IShareToken shareToken = IShareToken(address(syncVault.share()));

        // Retrieve async vault
        IVault asyncVault_ =
            syncVault.asyncRedeemManager().vaultByAssetId(syncVault.poolId(), syncVault.scId(), AssetId.wrap(assetId));
        assertNotEq(address(syncVault), address(0), "Failed to retrieve async vault");
        IAsyncRedeemVault asyncVault = IAsyncRedeemVault(address(asyncVault_));

        assertEq(address(syncVault), address(asyncVault));

        // Check price and max amounts
        uint256 shares = syncVault.previewDeposit(amount);
        uint256 assetsForShares = syncVault.previewMint(shares);
        assertEq(shares, amount / assetsPerShare, "shares, amount / assetsPerShare");
        assertEq(assetsForShares, amount, "assetsForShares, amount");
        assertEq(syncVault.maxDeposit(self), MAX_UINT128, "syncVault.maxDeposit(self) != type(uint128).max");
        assertEq(
            syncVault.maxMint(self),
            syncVault.convertToShares(MAX_UINT128),
            "syncVault.maxMint(self) != convertToShares(MAX_UINT128)"
        );

        // Will fail - user not member: can not send funds
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        syncVault.deposit(amount, self);

        assertEq(syncVault.isPermissioned(self), false);
        centrifugeChain.updateMember(syncVault.poolId().raw(), syncVault.scId().raw(), self, type(uint64).max);
        assertEq(syncVault.isPermissioned(self), true);

        // Will fail - user did not give asset allowance to syncVault
        vm.expectPartialRevert(IERC7751.WrappedError.selector);
        syncVault.deposit(amount, self);
        erc20.approve(address(syncVault), amount);

        // Will fail - above max reserve
        centrifugeChain.updateMaxReserve(
            syncVault.poolId().raw(), syncVault.scId().raw(), address(syncVault), uint128(amount / 2)
        );

        vm.expectRevert(IBaseRequestManager.ExceedsMaxDeposit.selector);
        syncVault.deposit(amount, self);

        centrifugeChain.updateMaxReserve(
            syncVault.poolId().raw(), syncVault.scId().raw(), address(syncVault), uint128(amount)
        );

        if (snap) {
            vm.startSnapshotGas("SyncDepositVault", "deposit_withoutQueue");
        }
        // _assertDepositEvents(syncVault, shares.toUint128(), pricePoolPerShare, pricePoolPerAsset);
        syncVault.deposit(amount / 2, self);
        if (snap) {
            vm.stopSnapshotGas();
        }

        balanceSheet.setQueue(syncVault.poolId(), syncVault.scId(), true);

        if (snap) {
            vm.startSnapshotGas("SyncDepositVault", "deposit_withQueue");
        }
        // _assertDepositEvents(syncVault, shares.toUint128(), pricePoolPerShare, pricePoolPerAsset);
        syncVault.deposit(amount / 2, self);
        if (snap) {
            vm.stopSnapshotGas();
        }

        assertEq(erc20.balanceOf(self), 0, "Mismatch in sync deposited amount");
        assertApproxEqAbs(shareToken.balanceOf(self), shares, 1, "Mismatch in amount of sync received shares");
        uint256 shareBalance = shareToken.balanceOf(self);

        // Can now request redemption through async syncVault
        assertEq(asyncVault.pendingRedeemRequest(0, self), 0);
        asyncVault.requestRedeem(shareBalance, self, self);
        assertEq(asyncVault.pendingRedeemRequest(0, self), shareBalance);

        spoke.unlinkVault(syncVault.poolId(), syncVault.scId(), AssetId.wrap(assetId), syncVault);
        assertEq(syncVault.maxDeposit(address(this)), 0);
        assertEq(syncVault.maxMint(address(this)), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        syncVault.deposit(1, self);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        syncVault.mint(1, self);
    }
}
