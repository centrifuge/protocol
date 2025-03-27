// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/CastLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {SyncDepositAsyncRedeemVault} from "src/vaults/SyncDepositAsyncRedeemVault.sol";
import {ISyncInvestmentManager} from "src/vaults/interfaces/investments/ISyncInvestmentManager.sol";

contract SyncDepositTest is BaseTest {
    using CastLib for *;
    using MessageLib for *;
    using MathLib for *;

    uint128 priceFactor = 2;
    uint128 price = priceFactor * 10 ** 18;

    function testSyncDeposit(uint256 amount) public {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        erc20.mint(self, amount);

        // Deploy sync vault
        (address syncVault_, uint128 assetId) = deploySimpleVault(VaultKind.SyncDepositAsyncRedeem);
        SyncDepositAsyncRedeemVault syncVault = SyncDepositAsyncRedeemVault(syncVault_);
        ITranche tranche = ITranche(address(syncVault.share()));
        centrifugeChain.updateTranchePrice(
            syncVault.poolId(), syncVault.trancheId(), assetId, price, uint64(block.timestamp)
        );

        // Retrieve async vault
        address asyncVault_ =
            syncVault.asyncManager().vaultByAssetId(syncVault.poolId(), syncVault.trancheId(), assetId);
        assertNotEq(syncVault_, address(0), "Failed to retrieve async vault");
        ERC7540Vault asyncVault = ERC7540Vault(asyncVault_);

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
        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        syncVault.deposit(amount, self);

        assertEq(syncVault.isPermissioned(self), false);
        centrifugeChain.updateMember(syncVault.poolId(), syncVault.trancheId(), self, type(uint64).max);
        assertEq(syncVault.isPermissioned(self), true);

        syncVault.deposit(amount, self);
        assertEq(erc20.balanceOf(self), 0, "Mismatch in sync deposited amount");
        assertEq(tranche.balanceOf(self), shares, "Mismatch in amount of sync received shares");

        // Can now request redemption through async syncVault
        assertEq(asyncVault.pendingRedeemRequest(0, self), 0);
        asyncVault.requestRedeem(amount / 2, self, self);
        assertEq(asyncVault.pendingRedeemRequest(0, self), amount / 2);
    }
}
