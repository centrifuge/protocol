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
import {JournalEntry} from "src/common/libraries/JournalEntryLib.sol";

import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {SyncDepositVault} from "src/vaults/SyncDepositVault.sol";
import {VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {ISyncRequests} from "src/vaults/interfaces/investments/ISyncRequests.sol";

contract SyncDepositTest is BaseTest {
    using CastLib for *;
    using MessageLib for *;
    using MathLib for *;

    uint128 priceFactor = 2;
    uint128 price = priceFactor * 10 ** 18;

    function testSyncDeposit(uint256 amount) public {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128 / priceFactor));
        vm.assume(amount % 2 == 0);

        erc20.mint(self, amount);

        // Deploy sync vault
        (, address syncVault_, uint128 assetId) = deploySimpleVault(VaultKind.SyncDepositAsyncRedeem);
        SyncDepositVault syncVault = SyncDepositVault(syncVault_);
        IShareToken shareToken = IShareToken(address(syncVault.share()));
        centrifugeChain.updatePricePoolPerShare(
            syncVault.poolId(), syncVault.trancheId(), price, uint64(block.timestamp)
        );

        // Retrieve async vault
        address asyncVault_ =
            syncVault.asyncRedeemManager().vaultByAssetId(syncVault.poolId(), syncVault.trancheId(), assetId);
        assertNotEq(syncVault_, address(0), "Failed to retrieve async vault");
        AsyncVault asyncVault = AsyncVault(asyncVault_);

        // Check price and max amounts
        uint256 shares = syncVault.previewDeposit(amount);
        uint256 assetsForShares = syncVault.previewMint(shares);
        assertEq(shares, amount / priceFactor);
        assertEq(assetsForShares, amount);
        assertEq(syncVault.maxDeposit(self), type(uint256).max);
        assertEq(syncVault.maxMint(self), type(uint256).max);

        // Will fail - user did not give asset allowance to syncVault
        vm.expectRevert(SafeTransferLib.SafeTransferFromFailed.selector);
        syncVault.deposit(amount, self);
        erc20.approve(address(syncVault), amount);

        // Will fail - user not member: can not send funds
        vm.expectRevert(bytes("RestrictedTransfers/transfer-blocked"));
        syncVault.deposit(amount, self);

        assertEq(syncVault.isPermissioned(self), false);
        centrifugeChain.updateMember(syncVault.poolId(), syncVault.trancheId(), self, type(uint64).max);
        assertEq(syncVault.isPermissioned(self), true);

        _assertDepositEvents(syncVault, shares.toUint128());
        syncVault.deposit(amount, self);
        assertEq(erc20.balanceOf(self), 0, "Mismatch in sync deposited amount");
        assertEq(shareToken.balanceOf(self), shares, "Mismatch in amount of sync received shares");

        // Can now request redemption through async syncVault
        assertEq(asyncVault.pendingRedeemRequest(0, self), 0);
        asyncVault.requestRedeem(amount / 2, self, self);
        assertEq(asyncVault.pendingRedeemRequest(0, self), amount / 2);
    }

    function _assertDepositEvents(SyncDepositVault vault, uint128 shares) internal {
        PoolId poolId = PoolId.wrap(vault.poolId());
        ShareClassId scId = ShareClassId.wrap(vault.trancheId());
        D18 pricePerShare = d18(price);
        D18 pricePerUnit = d18(priceFactor, 1);
        uint64 timestamp = uint64(block.timestamp);
        uint128 depositAssetAmount = vault.previewMint(shares).toUint128();
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault));
        JournalEntry[] memory journalEntries = new JournalEntry[](0);

        vm.expectEmit(false, false, false, false);
        emit IGateway.SendMessage(bytes(""));
        vm.expectEmit();
        emit IBalanceSheet.Issue(poolId, scId, self, pricePerShare, shares);

        vm.expectEmit(false, false, false, false);
        emit IGateway.SendMessage(bytes(""));
        vm.expectEmit();
        emit IBalanceSheet.Deposit(
            poolId,
            scId,
            vault.asset(),
            vaultDetails.tokenId,
            syncRequests.escrow(),
            depositAssetAmount,
            pricePerUnit,
            timestamp,
            journalEntries,
            journalEntries
        );
    }
}
