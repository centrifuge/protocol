// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
pragma abicoder v2;

import {VaultBaseTest as BaseTest} from "./VaultBaseTest.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {IAsyncVault} from "../../../src/vaults/interfaces/IAsyncVault.sol";
import {IAsyncRequestManager} from "../../../src/vaults/interfaces/IVaultManagers.sol";

import {IShareToken} from "../../../src/token/interfaces/IShareToken.sol";

contract AsyncRequestManagerTest is BaseTest {
    function testSuccess(uint128 depositAmount) public {
        depositAmount = uint128(bound(depositAmount, 2, MAX_UINT128 / 2));

        (, address vaultAddress,) = deploySimpleVault(asyncVaultFactory);
        IAsyncVault vault = IAsyncVault(vaultAddress);

        uint128 assetId = spokeRegistry.assetToId(address(erc20), erc20TokenId).raw();

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

        (, address vaultAddress,) = deploySimpleVault(asyncVaultFactory);
        IAsyncVault vault = IAsyncVault(vaultAddress);

        uint128 assetId = spokeRegistry.assetToId(address(erc20), erc20TokenId).raw();

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

/// @dev Shares leave the pool escrow through a transfer the hook sees as `escrow -> receiver`, so the
///      controller they belong to is not a party to it. Without an explicit check a frozen controller
///      claims to any address that passes, while `maxMint` already reports 0 for them.
contract AsyncRequestManagerFrozenClaimTest is BaseTest {
    uint128 constant AMOUNT = 100e6;

    address accomplice = makeAddr("accomplice");

    function _fulfilledVault() internal returns (IAsyncVault vault) {
        (, address vaultAddress,) = deploySimpleVault(asyncVaultFactory);
        vault = IAsyncVault(vaultAddress);

        deposit(vaultAddress, investor, AMOUNT, false);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), accomplice, MAX_UINT64);
    }

    /// @dev A deposit request cancelled in full, so the refund is claimable and nothing was ever issued.
    function _cancelledDepositVault() internal returns (IAsyncVault vault) {
        (, address vaultAddress,) = deploySimpleVault(asyncVaultFactory);
        vault = IAsyncVault(vaultAddress);

        erc20.mint(investor, AMOUNT);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), investor, MAX_UINT64);

        vm.startPrank(investor);
        erc20.approve(vaultAddress, AMOUNT);
        vault.requestDeposit(AMOUNT, investor, investor);
        vault.cancelDepositRequest(0, investor);
        vm.stopPrank();

        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(),
            vault.scId().raw(),
            bytes32(bytes20(investor)),
            spokeRegistry.assetToId(address(erc20), erc20TokenId).raw(),
            0,
            0,
            AMOUNT
        );
    }

    function testFrozenControllerCannotMintToAnotherMember() public {
        IAsyncVault vault = _fulfilledVault();
        centrifugeChain.freeze(vault.poolId().raw(), vault.scId().raw(), investor);

        assertEq(vault.maxMint(investor), 0);

        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        vm.prank(investor);
        vault.mint(AMOUNT, accomplice);
    }

    /// @dev Membership expiry blocks the same claim as a freeze; only the view path was reachable before.
    function testExpiredMemberControllerCannotMintToAnotherMember() public {
        IAsyncVault vault = _fulfilledVault();
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), investor, uint64(block.timestamp));
        vm.warp(block.timestamp + 1);

        assertEq(vault.maxMint(investor), 0);

        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        vm.prank(investor);
        vault.mint(AMOUNT, accomplice);
    }

    function testFrozenControllerCannotDepositToAnotherMember() public {
        IAsyncVault vault = _fulfilledVault();
        centrifugeChain.freeze(vault.poolId().raw(), vault.scId().raw(), investor);

        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        vm.prank(investor);
        vault.deposit(AMOUNT, accomplice);
    }

    function testFrozenControllerCannotClaimCancelledRedeem() public {
        IAsyncVault vault = _fulfilledVault();
        uint128 assetId = spokeRegistry.assetToId(address(erc20), erc20TokenId).raw();

        vm.startPrank(investor);
        vault.mint(AMOUNT, investor);
        vault.requestRedeem(AMOUNT, investor, investor);
        vault.cancelRedeemRequest(0, investor);
        vm.stopPrank();

        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId().raw(), vault.scId().raw(), bytes32(bytes20(investor)), assetId, 0, 0, AMOUNT
        );
        centrifugeChain.freeze(vault.poolId().raw(), vault.scId().raw(), investor);

        assertEq(vault.claimableCancelRedeemRequest(0, investor), 0);

        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        vm.prank(investor);
        vault.claimCancelRedeemRequest(0, accomplice, investor);
    }

    function testFrozenControllerCannotClaimCancelledDeposit() public {
        IAsyncVault vault = _cancelledDepositVault();
        centrifugeChain.freeze(vault.poolId().raw(), vault.scId().raw(), investor);

        assertEq(vault.claimableCancelDepositRequest(0, investor), 0);

        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        vm.prank(investor);
        vault.claimCancelDepositRequest(0, investor, investor);
    }

    /// @dev The refund is in assets, but the write path gates it on the share token restrictions, so the
    ///      view has to report the same for the claim not to revert on a non-zero value.
    function testCancelledDepositRemainsClaimableWhileUnfrozen() public {
        IAsyncVault vault = _cancelledDepositVault();

        assertEq(vault.claimableCancelDepositRequest(0, investor), AMOUNT);

        vm.prank(investor);
        assertEq(vault.claimCancelDepositRequest(0, investor, investor), AMOUNT);
    }

    /// @dev An unfrozen controller still claims to a third party, so the check is not a blanket ban.
    function testControllerCanStillMintToAnotherMember() public {
        IAsyncVault vault = _fulfilledVault();

        vm.prank(investor);
        vault.mint(AMOUNT, accomplice);

        assertEq(IShareToken(vault.share()).balanceOf(accomplice), AMOUNT);
    }
}
