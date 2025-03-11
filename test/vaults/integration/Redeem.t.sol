// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

contract RedeemTest is BaseTest {
    using MessageLib for *;
    using CastLib for *;

    function testRedeem(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128 / 2));

        (address vault_, uint128 assetId) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(vault.share()));

        deposit(vault_, self, amount); // deposit funds first
        centrifugeChain.updateTranchePrice(
            vault.poolId(), vault.trancheId(), assetId, defaultPrice, uint64(block.timestamp)
        );

        // will fail - zero deposit not allowed
        vm.expectRevert(bytes("InvestmentManager/zero-amount-not-allowed"));
        vault.requestRedeem(0, self, self);

        // will fail - investment asset not allowed
        centrifugeChain.disallowAsset(vault.poolId(), assetId);
        vm.expectRevert(bytes("InvestmentManager/asset-not-allowed"));
        vault.requestRedeem(amount, address(this), address(this));

        // will fail - cannot fulfill if there is no pending redeem request
        uint128 assets = uint128((amount * 10 ** 18) / defaultPrice);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        vm.expectRevert(bytes("InvestmentManager/no-pending-redeem-request"));
        centrifugeChain.isFulfilledRedeemRequest(
            poolId, trancheId, bytes32(bytes20(self)), assetId, assets, uint128(amount)
        );

        // success
        centrifugeChain.allowAsset(vault.poolId(), assetId);
        vault.requestRedeem(amount, address(this), address(this));
        assertEq(tranche.balanceOf(address(escrow)), amount);
        assertEq(vault.pendingRedeemRequest(0, self), amount);
        assertEq(vault.claimableRedeemRequest(0, self), 0);

        // fail: no tokens left
        vm.expectRevert(bytes("ERC7540Vault/insufficient-balance"));
        vault.requestRedeem(amount, address(this), address(this));

        // trigger executed collectRedeem
        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(self)), assetId, assets, uint128(amount)
        );

        // assert withdraw & redeem values adjusted
        assertEq(vault.maxWithdraw(self), assets); // max deposit
        assertEq(vault.maxRedeem(self), amount); // max deposit
        assertEq(vault.pendingRedeemRequest(0, self), 0);
        assertEq(vault.claimableRedeemRequest(0, self), amount);
        assertEq(tranche.balanceOf(address(escrow)), 0);
        assertEq(erc20.balanceOf(address(escrow)), assets);

        // can redeem to self
        vault.redeem(amount / 2, self, self); // redeem half the amount to own wallet

        // can also redeem to another user on the memberlist
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), investor, type(uint64).max);
        vault.redeem(amount / 2, investor, self); // redeem half the amount to investor wallet

        assertEq(tranche.balanceOf(self), 0);
        assertTrue(tranche.balanceOf(address(escrow)) <= 1);
        assertTrue(erc20.balanceOf(address(escrow)) <= 1);

        assertApproxEqAbs(erc20.balanceOf(self), (amount / 2), 1);
        assertApproxEqAbs(erc20.balanceOf(investor), (amount / 2), 1);
        assertTrue(vault.maxWithdraw(self) <= 1);
        assertTrue(vault.maxRedeem(self) <= 1);

        // withdrawing or redeeming more should revert
        vm.expectRevert(bytes("InvestmentManager/exceeds-redeem-limits"));
        vault.withdraw(2, investor, self);
        vm.expectRevert(bytes("InvestmentManager/exceeds-max-redeem"));
        vault.redeem(2, investor, self);
    }

    function testWithdraw(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128 / 2));

        (address vault_, uint128 assetId) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(vault.share()));

        deposit(vault_, self, amount); // deposit funds first
        centrifugeChain.updateTranchePrice(
            vault.poolId(), vault.trancheId(), assetId, defaultPrice, uint64(block.timestamp)
        );

        vault.requestRedeem(amount, address(this), address(this));
        assertEq(tranche.balanceOf(address(escrow)), amount);
        assertGt(vault.pendingRedeemRequest(0, self), 0);

        // trigger executed collectRedeem
        uint128 assets = uint128((amount * 10 ** 18) / defaultPrice);
        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(self)), assetId, assets, uint128(amount)
        );

        // assert withdraw & redeem values adjusted
        assertEq(vault.maxWithdraw(self), assets); // max deposit
        assertEq(vault.maxRedeem(self), amount); // max deposit
        assertEq(tranche.balanceOf(address(escrow)), 0);
        assertEq(erc20.balanceOf(address(escrow)), assets);

        // can redeem to self
        vault.withdraw(amount / 2, self, self); // redeem half the amount to own wallet

        // can also withdraw to another user on the memberlist
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), investor, type(uint64).max);
        vault.withdraw(amount / 2, investor, self); // redeem half the amount to investor wallet

        assertTrue(tranche.balanceOf(self) <= 1);
        assertTrue(erc20.balanceOf(address(escrow)) <= 1);
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

        (address vault_,) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(vault.share()));

        deposit(vault_, investor, amount); // deposit funds first // deposit funds first

        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        vault.requestRedeem(amount, investor, investor);

        assertEq(tranche.allowance(investor, address(this)), 0);
        vm.prank(investor);
        tranche.approve(address(this), amount);
        assertEq(tranche.allowance(investor, address(this)), amount);

        // investor can requestRedeem
        vault.requestRedeem(amount, investor, investor);
        assertEq(tranche.allowance(investor, address(this)), 0);
    }

    function testCancelRedeemOrder(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128 / 2));

        (address vault_, uint128 assetId) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(vault.share()));
        deposit(vault_, self, amount * 2); // deposit funds first

        vm.expectRevert(bytes("InvestmentManager/no-pending-redeem-request"));
        vault.cancelRedeemRequest(0, self);

        vault.requestRedeem(amount, address(this), address(this));

        // will fail - user not member
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, uint64(block.timestamp));
        vm.warp(block.timestamp + 1);
        vm.expectRevert(bytes("InvestmentManager/transfer-not-allowed"));
        vault.cancelRedeemRequest(0, self);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);

        assertEq(tranche.balanceOf(address(escrow)), amount);
        assertEq(tranche.balanceOf(self), amount);

        // check message was send out to centchain
        vault.cancelRedeemRequest(0, self);

        MessageLib.CancelRedeemRequest memory m = adapter1.values_bytes("send").deserializeCancelRedeemRequest();
        assertEq(m.poolId, vault.poolId());
        assertEq(m.scId, vault.trancheId());
        assertEq(m.investor, bytes32(bytes20(self)));
        assertEq(m.assetId, assetId);

        assertEq(vault.pendingCancelRedeemRequest(0, self), true);

        // Cannot cancel twice
        vm.expectRevert(bytes("InvestmentManager/cancellation-is-pending"));
        vault.cancelRedeemRequest(0, self);

        vm.expectRevert(bytes("InvestmentManager/cancellation-is-pending"));
        vault.requestRedeem(amount, address(this), address(this));

        centrifugeChain.isFulfilledCancelRedeemRequest(
            vault.poolId(), vault.trancheId(), self.toBytes32(), assetId, uint128(amount)
        );

        assertEq(tranche.balanceOf(address(escrow)), amount);
        assertEq(tranche.balanceOf(self), amount);
        assertEq(vault.claimableCancelRedeemRequest(0, self), amount);
        assertEq(vault.pendingCancelRedeemRequest(0, self), false);

        // After cancellation is executed, new request can be submitted
        vault.requestRedeem(amount, address(this), address(this));
    }

    function testTriggerRedeemRequestTokens(uint128 amount) public {
        amount = uint128(bound(amount, 2, (MAX_UINT128 - 1)));

        (address vault_, uint128 assetId) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(vault.share()));
        deposit(vault_, investor, amount, false); // request and execute deposit, but don't claim
        assertEq(vault.maxMint(investor), amount);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();

        vm.prank(investor);
        vault.mint(amount / 2, investor); // investor mints half of the amount

        assertApproxEqAbs(tranche.balanceOf(investor), amount / 2, 1);
        assertApproxEqAbs(tranche.balanceOf(address(escrow)), amount / 2, 1);
        assertApproxEqAbs(vault.maxMint(investor), amount / 2, 1);

        // Fail - Redeem amount too big
        vm.expectRevert(IERC20.InsufficientBalance.selector);
        centrifugeChain.triggerIncreaseRedeemOrder(poolId, trancheId, investor, assetId, uint128(amount + 1));

        //Fail - Tranche token amount zero
        vm.expectRevert(bytes("InvestmentManager/tranche-token-amount-is-zero"));
        centrifugeChain.triggerIncreaseRedeemOrder(poolId, trancheId, investor, assetId, 0);

        // should work even if investor is frozen
        centrifugeChain.freeze(poolId, trancheId, investor); // freeze investor
        assertTrue(!Tranche(address(vault.share())).checkTransferRestriction(investor, address(escrow), amount));

        // half of the amount will be trabsferred from the investor's wallet & half of the amount will be taken from
        // escrow
        centrifugeChain.triggerIncreaseRedeemOrder(poolId, trancheId, investor, assetId, amount);

        assertApproxEqAbs(tranche.balanceOf(investor), 0, 1);
        assertApproxEqAbs(tranche.balanceOf(address(escrow)), amount, 1);
        assertEq(vault.maxMint(investor), 0);

        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(investor)), assetId, uint128(amount), uint128(amount)
        );

        vm.expectRevert(bytes("InvestmentManager/exceeds-max-redeem"));
        vm.prank(investor);
        vault.redeem(amount, investor, investor);
    }

    function testTriggerRedeemRequestTokensWithCancellation(uint128 amount) public {
        amount = uint128(bound(amount, 2, (MAX_UINT128 - 1)));
        vm.assume(amount % 2 == 0);

        (address vault_, uint128 assetId) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(vault.share()));
        deposit(vault_, investor, amount, false); // request and execute deposit, but don't claim
        assertEq(vault.maxMint(investor), amount);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();

        vm.prank(investor);
        vault.mint(amount, investor); // investor mints half of the amount

        assertApproxEqAbs(tranche.balanceOf(investor), amount, 1);
        assertApproxEqAbs(tranche.balanceOf(address(escrow)), 0, 1);
        assertApproxEqAbs(vault.maxMint(investor), 0, 1);

        // investor submits request to redeem half the amount
        vm.prank(investor);
        vault.requestRedeem(amount / 2, investor, investor);
        assertEq(tranche.balanceOf(address(escrow)), amount / 2);
        assertEq(tranche.balanceOf(investor), amount / 2);
        // investor cancels outstanding cancellation request
        vm.prank(investor);
        vault.cancelRedeemRequest(0, investor);
        assertEq(vault.pendingCancelRedeemRequest(0, investor), true);
        // redeem request can still be triggered for the other half of the investors tokens even though the investor has
        // an outstanding cancellation
        centrifugeChain.triggerIncreaseRedeemOrder(poolId, trancheId, investor, assetId, amount / 2);
        assertApproxEqAbs(tranche.balanceOf(investor), 0, 1);
        assertApproxEqAbs(tranche.balanceOf(address(escrow)), amount, 1);
        assertEq(vault.maxMint(investor), 0);
    }

    function testTriggerRedeemRequestTokensUnmintedTokensInEscrow(uint128 amount) public {
        amount = uint128(bound(amount, 2, (MAX_UINT128 - 1)));

        (address vault_, uint128 assetId) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(vault.share()));
        deposit(vault_, investor, amount, false); // request and execute deposit, but don't claim
        assertEq(vault.maxMint(investor), amount);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();

        // Fail - Redeem amount too big
        vm.expectRevert(IERC20.InsufficientBalance.selector);
        centrifugeChain.triggerIncreaseRedeemOrder(poolId, trancheId, investor, assetId, uint128(amount + 1));

        // should work even if investor is frozen
        centrifugeChain.freeze(poolId, trancheId, investor); // freeze investor
        assertTrue(!Tranche(address(vault.share())).checkTransferRestriction(investor, address(escrow), amount));

        // Test trigger partial redeem (maxMint > redeemAmount), where investor did not mint their tokens - user tokens
        // are still locked in escrow
        uint128 redeemAmount = uint128(amount / 2);
        centrifugeChain.triggerIncreaseRedeemOrder(poolId, trancheId, investor, assetId, redeemAmount);
        assertApproxEqAbs(tranche.balanceOf(address(escrow)), amount, 1);
        assertEq(tranche.balanceOf(investor), 0);

        // Test trigger full redeem (maxMint = redeemAmount), where investor did not mint their tokens - user tokens are
        // still locked in escrow
        redeemAmount = uint128(amount - redeemAmount);
        centrifugeChain.triggerIncreaseRedeemOrder(poolId, trancheId, investor, assetId, redeemAmount);
        assertApproxEqAbs(tranche.balanceOf(address(escrow)), amount, 1);
        assertEq(tranche.balanceOf(investor), 0);
        assertEq(vault.maxMint(investor), 0);

        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(investor)), assetId, uint128(amount), uint128(amount)
        );

        vm.expectRevert(bytes("InvestmentManager/exceeds-max-redeem"));
        vm.prank(investor);
        vault.redeem(amount, investor, investor);
    }

    function testPartialRedemptionExecutions() public {
        (address vault_, uint128 assetId) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(vault.share()));
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        ERC20 asset = ERC20(address(vault.asset()));
        centrifugeChain.updateTranchePrice(poolId, trancheId, assetId, 1000000000000000000, uint64(block.timestamp));

        // invest
        uint256 investmentAmount = 100000000; // 100 * 10**6
        centrifugeChain.updateMember(poolId, trancheId, self, type(uint64).max);
        asset.approve(address(investmentManager), investmentAmount);
        asset.mint(self, investmentAmount);
        erc20.approve(address(vault), investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        uint128 shares = 100000000;
        centrifugeChain.isFulfilledDepositRequest(
            poolId, trancheId, bytes32(bytes20(self)), assetId, uint128(investmentAmount), shares
        );

        (,, uint256 depositPrice,,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(depositPrice, 1000000000000000000);

        // assert deposit & mint values adjusted
        assertApproxEqAbs(vault.maxDeposit(self), investmentAmount, 2);
        assertEq(vault.maxMint(self), shares);

        // collect the tranche tokens
        vault.mint(shares, self);
        assertEq(tranche.balanceOf(self), shares);

        // redeem
        vault.requestRedeem(shares, self, self);

        // trigger first executed collectRedeem at a price of 1.5
        // user is able to redeem 50 tranche tokens, at 1.5 price, 75 asset is paid out
        uint128 assets = 75000000; // 150*10**6

        // mint approximate interest amount into escrow
        asset.mint(address(escrow), assets * 2 - investmentAmount);

        centrifugeChain.isFulfilledRedeemRequest(poolId, trancheId, bytes32(bytes20(self)), assetId, assets, shares / 2);

        (,,, uint256 redeemPrice,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(redeemPrice, 1500000000000000000);

        // trigger second executed collectRedeem at a price of 1.0
        // user has 50 tranche tokens left, at 1.0 price, 50 asset is paid out
        assets = 50000000; // 50*10**6

        centrifugeChain.isFulfilledRedeemRequest(poolId, trancheId, bytes32(bytes20(self)), assetId, assets, shares / 2);

        (,,, redeemPrice,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(redeemPrice, 1250000000000000000);
    }

    function partialRedeem(uint64 poolId, bytes16 trancheId, ERC7540Vault vault, ERC20 asset) public {
        ITranche tranche = ITranche(address(vault.share()));

        uint128 assetId = poolManager.assetToId(address(asset));
        uint256 totalTranches = tranche.balanceOf(self);
        uint256 redeemAmount = 50000000000000000000;
        assertTrue(redeemAmount <= totalTranches);
        vault.requestRedeem(redeemAmount, self, self);

        // first trigger executed collectRedeem of the first 25 tranches at a price of 1.1
        uint128 firstTrancheRedeem = 25000000000000000000;
        uint128 secondTrancheRedeem = 25000000000000000000;
        assertEq(firstTrancheRedeem + secondTrancheRedeem, redeemAmount);
        uint128 firstCurrencyPayout = 27500000; // (25000000000000000000/10**18) * 10**6 * 1.1

        centrifugeChain.isFulfilledRedeemRequest(
            poolId, trancheId, bytes32(bytes20(self)), assetId, firstCurrencyPayout, firstTrancheRedeem
        );

        assertEq(vault.maxRedeem(self), firstTrancheRedeem);

        (,,, uint256 redeemPrice,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(redeemPrice, 1100000000000000000);

        // second trigger executed collectRedeem of the second 25 tranches at a price of 1.3
        uint128 secondCurrencyPayout = 32500000; // (25000000000000000000/10**18) * 10**6 * 1.3
        centrifugeChain.isFulfilledRedeemRequest(
            poolId, trancheId, bytes32(bytes20(self)), assetId, secondCurrencyPayout, secondTrancheRedeem
        );

        (,,, redeemPrice,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(redeemPrice, 1200000000000000000);

        assertApproxEqAbs(vault.maxWithdraw(self), firstCurrencyPayout + secondCurrencyPayout, 2);
        assertEq(vault.maxRedeem(self), redeemAmount);

        // collect the asset
        vault.redeem(redeemAmount, self, self);
        assertEq(tranche.balanceOf(self), totalTranches - redeemAmount);
        assertEq(asset.balanceOf(self), firstCurrencyPayout + secondCurrencyPayout);
    }
}
