// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "../../../src/misc/types/D18.sol";
import {IERC20} from "../../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {RequestMessageLib} from "../../../src/common/libraries/RequestMessageLib.sol";

import "../../spoke/integration/BaseTest.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {IAsyncRequestManager} from "../../../src/vaults/interfaces/IVaultManagers.sol";

contract RedeemTest is BaseTest {
    using MessageLib for *;
    using RequestMessageLib for *;
    using CastLib for *;

    function testRedeem(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128 / 2));

        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(vault.share()));

        deposit(vault_, self, amount); // deposit funds first
        centrifugeChain.updatePricePoolPerShare(
            vault.poolId().raw(), vault.scId().raw(), defaultPrice, uint64(block.timestamp)
        );

        // will fail - zero deposit not allowed
        vm.expectRevert(IAsyncRequestManager.ZeroAmountNotAllowed.selector);
        vault.requestRedeem(0, self, self);

        // will fail - investment asset not allowed
        centrifugeChain.unlinkVault(vault.poolId().raw(), vault.scId().raw(), vault_);
        vm.expectRevert(IAsyncRequestManager.VaultNotLinked.selector);
        vault.requestRedeem(amount, address(this), address(this));

        // will fail - cannot fulfill if there is no pending redeem request
        uint128 assets = uint128((amount * 10 ** 18) / defaultPrice);
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        vm.expectRevert(IAsyncRequestManager.NoPendingRequest.selector);
        asyncRequestManager.fulfillRedeemRequest(poolId, scId, self, AssetId.wrap(assetId), assets, uint128(amount), 0);

        // success
        centrifugeChain.linkVault(vault.poolId().raw(), vault.scId().raw(), vault_);
        vault.requestRedeem(amount, address(this), address(this));
        assertEq(shareToken.balanceOf(address(globalEscrow)), amount);
        assertEq(vault.pendingRedeemRequest(0, self), amount);
        assertEq(vault.claimableRedeemRequest(0, self), 0);

        // fail: no tokens left
        vm.expectRevert(IBaseVault.InsufficientBalance.selector);
        vault.requestRedeem(amount, address(this), address(this));

        // trigger executed collectRedeem
        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId().raw(), vault.scId().raw(), bytes32(bytes20(self)), assetId, assets, uint128(amount), 0
        );

        // assert withdraw & redeem values adjusted
        assertEq(vault.maxWithdraw(self), assets); // max deposit
        assertEq(vault.maxRedeem(self), amount); // max deposit
        assertEq(vault.pendingRedeemRequest(0, self), 0);
        assertEq(vault.claimableRedeemRequest(0, self), amount);
        assertEq(shareToken.balanceOf(address(globalEscrow)), 0);
        assertEq(erc20.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), assets);

        // can redeem to self
        vault.redeem(amount / 2, self, self); // redeem half the amount to own wallet

        // can also redeem to another user on the memberlist
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), investor, type(uint64).max);
        vault.redeem(amount / 2, investor, self); // redeem half the amount to investor wallet

        assertEq(shareToken.balanceOf(self), 0);

        assertTrue(shareToken.balanceOf(address(globalEscrow)) <= 1);
        assertTrue(erc20.balanceOf(address(globalEscrow)) <= 1);

        assertApproxEqAbs(erc20.balanceOf(self), (amount / 2), 1);
        assertApproxEqAbs(erc20.balanceOf(investor), (amount / 2), 1);
        assertTrue(vault.maxWithdraw(self) <= 1);
        assertTrue(vault.maxRedeem(self) <= 1);

        // withdrawing or redeeming more should revert
        vm.expectRevert(IAsyncRequestManager.ExceedsRedeemLimits.selector);
        vault.withdraw(2, investor, self);
        vm.expectRevert(IAsyncRequestManager.ExceedsMaxRedeem.selector);
        vault.redeem(2, investor, self);
    }

    function testWithdraw(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128 / 2));

        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(vault.share()));

        deposit(vault_, self, amount); // deposit funds first
        centrifugeChain.updatePricePoolPerShare(
            vault.poolId().raw(), vault.scId().raw(), defaultPrice, uint64(block.timestamp)
        );

        vault.requestRedeem(amount, address(this), address(this));
        assertEq(shareToken.balanceOf(address(globalEscrow)), amount);
        assertGt(vault.pendingRedeemRequest(0, self), 0);

        // trigger executed collectRedeem
        uint128 assets = uint128((amount * 10 ** 18) / defaultPrice);
        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId().raw(), vault.scId().raw(), bytes32(bytes20(self)), assetId, assets, uint128(amount), 0
        );

        // assert withdraw & redeem values adjusted
        assertEq(vault.maxWithdraw(self), assets); // max deposit
        assertEq(vault.maxRedeem(self), amount); // max deposit
        assertEq(shareToken.balanceOf(address(globalEscrow)), 0);
        assertEq(erc20.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), assets);

        // can redeem to self
        vault.withdraw(amount / 2, self, self); // redeem half the amount to own wallet

        // can also withdraw to another user on the memberlist
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), investor, type(uint64).max);
        vault.withdraw(amount / 2, investor, self); // redeem half the amount to investor wallet

        assertTrue(shareToken.balanceOf(self) <= 1);
        assertTrue(erc20.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))) <= 1);
        assertApproxEqAbs(erc20.balanceOf(self), assets / 2, 1);
        assertApproxEqAbs(erc20.balanceOf(investor), assets / 2, 1);
        assertTrue(vault.maxRedeem(self) <= 1);
        assertTrue(vault.maxWithdraw(self) <= 1);
    }

    function testRequestRedeemWithApproval(uint256 redemption1, uint256 redemption2) public {
        vm.assume(investor != address(this));

        redemption1 = uint128(bound(redemption1, 2, MAX_UINT128 / 4));
        redemption2 = uint128(bound(redemption2, 2, MAX_UINT128 / 4));
        uint256 amount = redemption1 + redemption2;
        vm.assume(amountAssumption(amount));

        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(vault.share()));

        deposit(vault_, investor, amount); // deposit funds first // deposit funds first

        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        vault.requestRedeem(amount, investor, investor);

        assertEq(shareToken.allowance(investor, address(this)), 0);
        vm.prank(investor);
        shareToken.approve(address(this), amount);
        assertEq(shareToken.allowance(investor, address(this)), amount);

        // investor can requestRedeem
        vault.requestRedeem(amount, investor, investor);
        assertEq(shareToken.allowance(investor, address(this)), 0);
    }

    function testCancelRedeemOrder(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128 / 2));

        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(vault.share()));
        deposit(vault_, self, amount * 2); // deposit funds first

        vm.expectRevert(IAsyncRequestManager.NoPendingRequest.selector);
        vault.cancelRedeemRequest(0, self);

        vault.requestRedeem(amount, address(this), address(this));

        // will fail - user not member
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, uint64(block.timestamp));
        vm.warp(block.timestamp + 1);
        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        vault.cancelRedeemRequest(0, self);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);

        assertEq(shareToken.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), 0);
        assertEq(shareToken.balanceOf(address(globalEscrow)), amount);
        assertEq(shareToken.balanceOf(self), amount);

        // check message was send out to centchain
        vault.cancelRedeemRequest(0, self);

        MessageLib.Request memory m = adapter1.values_bytes("send").deserializeRequest();
        assertEq(m.poolId, vault.poolId().raw());
        assertEq(m.scId, vault.scId().raw());
        assertEq(m.assetId, assetId);
        RequestMessageLib.CancelRedeemRequest memory cb = RequestMessageLib.deserializeCancelRedeemRequest(m.payload);
        assertEq(cb.investor, bytes32(bytes20(self)));

        assertEq(vault.pendingCancelRedeemRequest(0, self), true);

        // Cannot cancel twice
        vm.expectRevert(IAsyncRequestManager.CancellationIsPending.selector);
        vault.cancelRedeemRequest(0, self);

        vm.expectRevert(IAsyncRequestManager.CancellationIsPending.selector);
        vault.requestRedeem(amount, address(this), address(this));

        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId().raw(), vault.scId().raw(), self.toBytes32(), assetId, 0, 0, uint128(amount)
        );

        assertEq(shareToken.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), 0);
        assertEq(shareToken.balanceOf(address(globalEscrow)), amount);
        assertEq(shareToken.balanceOf(self), amount);
        assertEq(vault.claimableCancelRedeemRequest(0, self), amount);
        assertEq(vault.pendingCancelRedeemRequest(0, self), false);

        // After cancellation is executed, new request can be submitted
        vault.requestRedeem(amount, address(this), address(this));
    }

    function testPartialRedemptionExecutions() public {
        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(vault.share()));
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        ERC20 asset = ERC20(address(vault.asset()));
        centrifugeChain.updatePricePoolPerShare(poolId.raw(), scId.raw(), 1000000000000000000, uint64(block.timestamp));

        // invest
        uint256 investmentAmount = 100000000; // 100 * 10**6
        centrifugeChain.updateMember(poolId.raw(), scId.raw(), self, type(uint64).max);
        asset.approve(address(asyncRequestManager), investmentAmount);
        asset.mint(self, investmentAmount);
        erc20.approve(address(vault), investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        uint128 shares = 100000000;
        centrifugeChain.isFulfilledDepositRequest(
            poolId.raw(), scId.raw(), bytes32(bytes20(self)), assetId, uint128(investmentAmount), shares, 0
        );

        (,, D18 depositPrice,,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(depositPrice.raw(), 1000000000000000000);

        // assert deposit & mint values adjusted
        assertApproxEqAbs(vault.maxDeposit(self), investmentAmount, 2);
        assertEq(vault.maxMint(self), shares);

        // collect the share class tokens
        vault.mint(shares, self);
        assertEq(shareToken.balanceOf(self), shares);

        // redeem
        vault.requestRedeem(shares, self, self);

        // trigger first executed collectRedeem at a price of 1.5
        // user is able to redeem 50 share class tokens, at 1.5 price, 75 asset is paid out
        uint128 assets = 75000000; // 150*10**6

        // mint approximate interest amount into escrow
        asset.mint(address(poolEscrowFactory.escrow(vault.poolId())), assets * 2 - investmentAmount);

        centrifugeChain.isFulfilledRedeemRequest(
            poolId.raw(), scId.raw(), bytes32(bytes20(self)), assetId, assets, shares / 2, 0
        );

        (,,, D18 redeemPrice,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(redeemPrice.raw(), 1500000000000000000);

        // trigger second executed collectRedeem at a price of 1.0
        // user has 50 share class tokens left, at 1.0 price, 50 asset is paid out
        assets = 50000000; // 50*10**6

        centrifugeChain.isFulfilledRedeemRequest(
            poolId.raw(), scId.raw(), bytes32(bytes20(self)), assetId, assets, shares / 2, 0
        );

        (,,, redeemPrice,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(redeemPrice.raw(), 1250000000000000000);
    }

    function partialRedeem(ShareClassId scId, AsyncVault vault, ERC20 asset) public {
        IShareToken shareToken = IShareToken(address(vault.share()));

        AssetId assetId = spoke.assetToId(address(asset), erc20TokenId);
        uint256 totalShares = shareToken.balanceOf(self);
        uint256 redeemAmount = 50000000000000000000;
        assertTrue(redeemAmount <= totalShares);
        vault.requestRedeem(redeemAmount, self, self);

        // first trigger executed collectRedeem of the first 25 share class tokens at a price of 1.1
        uint128 firstShareRedeem = 25000000000000000000;
        uint128 secondShareRedeem = 25000000000000000000;
        assertEq(firstShareRedeem + secondShareRedeem, redeemAmount);
        uint128 firstCurrencyPayout = 27500000; // (25000000000000000000/10**18) * 10**6 * 1.1

        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId().raw(),
            scId.raw(),
            bytes32(bytes20(self)),
            assetId.raw(),
            firstCurrencyPayout,
            firstShareRedeem,
            0
        );

        assertEq(vault.maxRedeem(self), firstShareRedeem);

        (,,, D18 redeemPrice,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(redeemPrice.raw(), 1100000000000000000);

        // second trigger executed collectRedeem of the second 25 share class tokens at a price of 1.3
        uint128 secondCurrencyPayout = 32500000; // (25000000000000000000/10**18) * 10**6 * 1.3
        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId().raw(),
            scId.raw(),
            bytes32(bytes20(self)),
            assetId.raw(),
            secondCurrencyPayout,
            secondShareRedeem,
            0
        );

        (,,, redeemPrice,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(redeemPrice.raw(), 1200000000000000000);

        assertApproxEqAbs(vault.maxWithdraw(self), firstCurrencyPayout + secondCurrencyPayout, 2);
        assertEq(vault.maxRedeem(self), redeemAmount);

        // collect the asset
        vault.redeem(redeemAmount, self, self);
        assertEq(shareToken.balanceOf(self), totalShares - redeemAmount);
        assertEq(asset.balanceOf(self), firstCurrencyPayout + secondCurrencyPayout);
    }
}
