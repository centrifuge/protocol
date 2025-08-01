// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "../../../src/misc/types/D18.sol";

import "../../spoke/integration/BaseTest.sol";

contract DepositRedeem is BaseTest {
    function testPartialDepositAndRedeemExecutions(bytes16 scId) public {
        uint8 SHARE_TOKEN_DECIMALS = 18; // Like DAI
        uint8 INVESTMENT_CURRENCY_DECIMALS = 6; // 6, like USDC

        ERC20 asset = _newErc20("Currency", "CR", INVESTMENT_CURRENCY_DECIMALS);
        (uint64 poolId, address vault_, uint128 assetId) = deployVault(
            VaultKind.Async, SHARE_TOKEN_DECIMALS, address(fullRestrictionsHook), scId, address(asset), 0, 0
        );
        AsyncVault vault = AsyncVault(vault_);

        centrifugeChain.updatePricePoolPerShare(poolId, scId, 1e18, uint64(block.timestamp));

        centrifugeChain.updatePricePoolPerAsset(poolId, scId, assetId, 1e18, uint64(block.timestamp));

        partialDeposit(poolId, scId, vault, asset);

        partialRedeem(poolId, scId, vault, asset);
    }

    // Helpers

    function partialDeposit(uint64 poolId, bytes16 scId, AsyncVault vault, ERC20 asset) public {
        vm.assume(poolId >> 48 != THIS_CHAIN_ID);

        IShareToken shareToken = IShareToken(address(vault.share()));

        uint256 investmentAmount = 100000000; // 100 * 10**6
        centrifugeChain.updateMember(poolId, scId, self, type(uint64).max);
        asset.approve(address(vault), investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        // first trigger executed collectInvest of the first 50% at a price of 1.4
        AssetId assetId = spoke.assetToId(address(asset), erc20TokenId); // retrieve assetId
        uint128 assets = 50000000; // 50 * 10**6
        uint128 firstSharePayout = 35714285714285714285; // 50 * 10**18 / 1.4, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, scId, bytes32(bytes20(self)), assetId.raw(), assets, firstSharePayout, 0
        );

        (,, D18 depositPrice,,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(depositPrice.raw(), 1400000000000000000);

        // second trigger executed collectInvest of the second 50% at a price of 1.2
        uint128 secondSharePayout = 41666666666666666666; // 50 * 10**18 / 1.2, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, scId, bytes32(bytes20(self)), assetId.raw(), assets, secondSharePayout, 0
        );

        (,, depositPrice,,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(depositPrice.raw(), 1292307679384615384);

        // assert deposit & mint values adjusted
        assertApproxEqAbs(vault.maxDeposit(self), assets * 2, 2);
        assertEq(vault.maxMint(self), firstSharePayout + secondSharePayout);

        // collect the share class tokens
        vault.mint(firstSharePayout + secondSharePayout, self);
        assertEq(shareToken.balanceOf(self), firstSharePayout + secondSharePayout);
    }

    function partialRedeem(uint64 poolId, bytes16 scId, AsyncVault vault, ERC20 asset) public {
        vm.assume(poolId >> 48 != THIS_CHAIN_ID);

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
            poolId, scId, bytes32(bytes20(self)), assetId.raw(), firstCurrencyPayout, firstShareRedeem, 0
        );

        assertEq(vault.maxRedeem(self), firstShareRedeem);

        (,,, D18 redeemPrice,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(redeemPrice.raw(), 1100000000000000000);

        // second trigger executed collectRedeem of the second 25 share class tokens at a price of 1.3
        uint128 secondCurrencyPayout = 32500000; // (25000000000000000000/10**18) * 10**6 * 1.3
        centrifugeChain.isFulfilledRedeemRequest(
            poolId, scId, bytes32(bytes20(self)), assetId.raw(), secondCurrencyPayout, secondShareRedeem, 0
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
