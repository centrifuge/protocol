// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/CastLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";

import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {IHook} from "src/vaults/interfaces/token/IHook.sol";
import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {SyncDepositVault} from "src/vaults/SyncDepositVault.sol";
import {VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {ISyncRequests} from "src/vaults/interfaces/investments/ISyncRequests.sol";

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
            syncVault.poolId(), syncVault.trancheId(), pricePoolPerShare.inner(), uint64(block.timestamp)
        );
        centrifugeChain.updatePricePoolPerAsset(
            syncVault.poolId(), syncVault.trancheId(), assetId, pricePoolPerAsset.inner(), uint64(block.timestamp)
        );
    }

    function _assertDepositEvents(SyncDepositVault vault, uint128 shares, D18 pricePoolPerShare, D18 priceAssetPerShare)
        internal
    {
        PoolId poolId = PoolId.wrap(vault.poolId());
        ShareClassId scId = ShareClassId.wrap(vault.trancheId());
        uint64 timestamp = uint64(block.timestamp);
        uint128 depositAssetAmount = vault.previewMint(shares).toUint128();
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault));

        vm.expectEmit();
        emit IBalanceSheet.Issue(poolId, scId, self, pricePoolPerShare, shares);

        vm.expectEmit();
        emit IBalanceSheet.Deposit(
            poolId,
            scId,
            vault.asset(),
            vaultDetails.tokenId,
            address(poolEscrowFactory.escrow(poolId.raw())),
            depositAssetAmount,
            priceAssetPerShare,
            timestamp
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

    function testSyncDepositERC20(uint256 amount) public {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128 / assetsPerShare));
        vm.assume(amount % 2 == 0);

        // Fund such that we can deposit
        erc20.mint(self, amount);

        // Deploy sync vault
        (SyncDepositVault syncVault, uint128 assetId) = _deploySyncDepositVault(pricePoolPerShare, pricePoolPerAsset);
        IShareToken shareToken = IShareToken(address(syncVault.share()));

        // Retrieve async vault
        address asyncVault_ =
            syncVault.asyncRedeemManager().vaultByAssetId(syncVault.poolId(), syncVault.trancheId(), assetId);
        assertNotEq(address(syncVault), address(0), "Failed to retrieve async vault");
        AsyncVault asyncVault = AsyncVault(asyncVault_);

        // Check price and max amounts
        uint256 shares = syncVault.previewDeposit(amount);
        uint256 assetsForShares = syncVault.previewMint(shares);
        assertEq(shares, amount / assetsPerShare, "shares, amount / assetsPerShare");
        assertEq(assetsForShares, amount, "assetsForShares, amount");
        assertEq(syncVault.maxDeposit(self), type(uint256).max, "syncVault.maxDeposit(self), type(uint256).max");
        assertEq(syncVault.maxMint(self), type(uint256).max, "syncVault.maxMint(self), type(uint256).max");

        // Will fail - user did not give asset allowance to syncVault
        vm.expectRevert(SafeTransferLib.SafeTransferFromFailed.selector);
        syncVault.deposit(amount, self);
        erc20.approve(address(syncVault), amount);

        // Will fail - user not member: can not send funds
        vm.expectRevert(IHook.TransferBlocked.selector);
        syncVault.deposit(amount, self);

        assertEq(syncVault.isPermissioned(self), false);
        centrifugeChain.updateMember(syncVault.poolId(), syncVault.trancheId(), self, type(uint64).max);
        assertEq(syncVault.isPermissioned(self), true);

        // Will fail - above max reserve
        centrifugeChain.updateMaxReserve(
            syncVault.poolId(), syncVault.trancheId(), address(syncVault), uint128(amount / 2)
        );

        vm.expectRevert(ISyncRequests.ExceedsMaxReserve.selector);
        syncVault.deposit(amount, self);

        centrifugeChain.updateMaxReserve(syncVault.poolId(), syncVault.trancheId(), address(syncVault), uint128(amount));

        _assertDepositEvents(syncVault, shares.toUint128(), pricePoolPerShare, priceAssetPerShare);
        syncVault.deposit(amount, self);
        assertEq(erc20.balanceOf(self), 0, "Mismatch in sync deposited amount");
        assertEq(shareToken.balanceOf(self), shares, "Mismatch in amount of sync received shares");

        // Can now request redemption through async syncVault
        assertEq(asyncVault.pendingRedeemRequest(0, self), 0);
        asyncVault.requestRedeem(amount / 2, self, self);
        assertEq(asyncVault.pendingRedeemRequest(0, self), amount / 2);
    }
}
