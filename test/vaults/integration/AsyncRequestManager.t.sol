// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
pragma abicoder v2;

import "../../core/spoke/integration/BaseTest.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {IAsyncVault} from "../../../src/vaults/interfaces/IAsyncVault.sol";

contract AsyncRequestManagerTest is BaseTest {
    function testSuccess(uint128 depositAmount) public {
        depositAmount = uint128(bound(depositAmount, 2, MAX_UINT128 / 2));

        (, address vaultAddress,) = deploySimpleVault(VaultKind.Async);
        IAsyncVault vault = IAsyncVault(vaultAddress);

        uint128 assetId = spoke.assetToId(address(erc20), erc20TokenId).raw();

        deposit(vaultAddress, investor, depositAmount, false);

        uint128 sharesIssued = uint128(depositAmount);
        assertEq(vault.maxMint(investor), sharesIssued);
        assertEq(asyncRequestManager.pendingDepositRequest(IBaseVault(vaultAddress), investor), 0);

        vm.prank(investor);
        uint256 sharesMinted = vault.mint(sharesIssued, investor);

        assertEq(sharesMinted, sharesIssued);
        assertEq(IShareToken(vault.share()).balanceOf(investor), sharesIssued);
        assertEq(vault.maxMint(investor), 0);

        uint256 redeemAmount = sharesIssued / 2;

        vm.prank(investor);
        vault.requestRedeem(redeemAmount, investor, investor);

        assertEq(asyncRequestManager.pendingRedeemRequest(IBaseVault(vaultAddress), investor), redeemAmount);
        assertEq(vault.maxWithdraw(investor), 0);

        uint128 assetsReturned = uint128(redeemAmount);
        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId().raw(),
            vault.scId().raw(),
            bytes32(bytes20(investor)),
            assetId,
            assetsReturned,
            uint128(redeemAmount),
            0
        );

        assertEq(vault.maxWithdraw(investor), assetsReturned);
        assertEq(asyncRequestManager.pendingRedeemRequest(IBaseVault(vaultAddress), investor), 0);

        uint256 investorBalanceBefore = erc20.balanceOf(investor);

        vm.prank(investor);
        uint256 assetsWithdrawn = vault.withdraw(assetsReturned, investor, investor);

        assertEq(assetsWithdrawn, assetsReturned);
        assertEq(erc20.balanceOf(investor) - investorBalanceBefore, assetsReturned);
        assertEq(vault.maxWithdraw(investor), 0);

        uint256 expectedRemainingShares = sharesIssued - redeemAmount;
        assertEq(IShareToken(vault.share()).balanceOf(investor), expectedRemainingShares);
    }

    function testCancellations(uint128 depositAmount) public {
        depositAmount = uint128(bound(depositAmount, 100, MAX_UINT128 / 2));

        (, address vaultAddress,) = deploySimpleVault(VaultKind.Async);
        IAsyncVault vault = IAsyncVault(vaultAddress);

        uint128 assetId = spoke.assetToId(address(erc20), erc20TokenId).raw();

        erc20.mint(investor, depositAmount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), investor, type(uint64).max);

        vm.startPrank(investor);
        erc20.approve(vaultAddress, depositAmount);
        vault.requestDeposit(depositAmount, investor, investor);
        vault.cancelDepositRequest(0, investor);
        vm.stopPrank();

        assertEq(asyncRequestManager.pendingCancelDepositRequest(IBaseVault(vaultAddress), investor), true);

        uint128 fulfilledAssets = uint128((uint256(depositAmount) / 10) * 7); // 70% fulfilled
        uint128 cancelledAssets = depositAmount - fulfilledAssets;
        uint128 sharesIssued = fulfilledAssets;

        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(),
            vault.scId().raw(),
            bytes32(bytes20(investor)),
            assetId,
            fulfilledAssets,
            sharesIssued,
            cancelledAssets
        );

        assertEq(vault.maxMint(investor), sharesIssued);
        assertEq(asyncRequestManager.claimableCancelDepositRequest(IBaseVault(vaultAddress), investor), cancelledAssets);
        assertEq(asyncRequestManager.pendingCancelDepositRequest(IBaseVault(vaultAddress), investor), false);

        vm.prank(investor);
        vault.mint(sharesIssued, investor);

        uint256 investorBalanceBefore = erc20.balanceOf(investor);
        vm.prank(investor);
        uint256 cancelledClaimed = vault.claimCancelDepositRequest(0, investor, investor);

        assertEq(cancelledClaimed, cancelledAssets);
        assertEq(erc20.balanceOf(investor) - investorBalanceBefore, cancelledAssets);

        vm.prank(investor);
        vault.requestRedeem(sharesIssued, investor, investor);

        vm.prank(investor);
        vault.cancelRedeemRequest(0, investor);

        assertEq(asyncRequestManager.pendingCancelRedeemRequest(IBaseVault(vaultAddress), investor), true);

        uint128 fulfilledShares = uint128((uint256(sharesIssued) / 10) * 6); // 60% fulfilled
        uint128 cancelledShares = sharesIssued - fulfilledShares;
        uint128 assetsReturned = fulfilledShares;

        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId().raw(),
            vault.scId().raw(),
            bytes32(bytes20(investor)),
            assetId,
            assetsReturned,
            fulfilledShares,
            cancelledShares
        );

        assertEq(vault.maxWithdraw(investor), assetsReturned);
        assertEq(asyncRequestManager.claimableCancelRedeemRequest(IBaseVault(vaultAddress), investor), cancelledShares);
        assertEq(asyncRequestManager.pendingCancelRedeemRequest(IBaseVault(vaultAddress), investor), false);

        investorBalanceBefore = erc20.balanceOf(investor);
        vm.prank(investor);
        vault.withdraw(assetsReturned, investor, investor);

        assertEq(erc20.balanceOf(investor) - investorBalanceBefore, assetsReturned);

        uint256 shareBalanceBefore = IShareToken(vault.share()).balanceOf(investor);
        vm.prank(investor);
        uint256 cancelledSharesClaimed = vault.claimCancelRedeemRequest(0, investor, investor);

        assertEq(cancelledSharesClaimed, cancelledShares);
        assertEq(IShareToken(vault.share()).balanceOf(investor) - shareBalanceBefore, cancelledShares);
    }
}
