// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";

contract DepositRedeem is BaseTest {
    function testPartialDepositAndRedeemExecutions(uint64 poolId, bytes16 scId) public {
        vm.assume(poolId >> 48 != THIS_CHAIN_ID);

        uint8 SHARE_TOKEN_DECIMALS = 18; // Like DAI
        uint8 INVESTMENT_CURRENCY_DECIMALS = 6; // 6, like USDC

        ERC20 asset = _newErc20("Currency", "CR", INVESTMENT_CURRENCY_DECIMALS);
        (address vault_, uint128 assetId) = deployVault(
            VaultKind.Async, poolId, SHARE_TOKEN_DECIMALS, restrictedTransfers, "", "", scId, address(asset), 0, 0
        );
        AsyncVault vault = AsyncVault(vault_);

        centrifugeChain.updateSharePrice(poolId, scId, assetId, 1000000000000000000, uint64(block.timestamp));

        partialDeposit(poolId, scId, vault, asset);

        partialRedeem(poolId, scId, vault, asset);
    }

    // Helpers

    function partialDeposit(uint64 poolId, bytes16 scId, AsyncVault vault, ERC20 asset) public {
        vm.assume(poolId >> 48 != THIS_CHAIN_ID);

        IShareToken token = IShareToken(address(vault.share()));

        uint256 investmentAmount = 100000000; // 100 * 10**6
        centrifugeChain.updateMember(poolId, scId, self, type(uint64).max);
        asset.approve(address(vault), investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        // first trigger executed collectInvest of the first 50% at a price of 1.4
        uint128 _assetId = poolManager.assetToId(address(asset), erc20TokenId); // retrieve assetId
        uint128 assets = 50000000; // 50 * 10**6
        uint128 firstSharePayout = 35714285714285714285; // 50 * 10**18 / 1.4, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, scId, bytes32(bytes20(self)), _assetId, assets, firstSharePayout
        );

        (,, uint256 depositPrice,,,,,,,) = asyncRequests.investments(address(vault), self);
        assertEq(depositPrice, 1400000000000000000);

        // second trigger executed collectInvest of the second 50% at a price of 1.2
        uint128 secondSharePayout = 41666666666666666666; // 50 * 10**18 / 1.2, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, scId, bytes32(bytes20(self)), _assetId, assets, secondSharePayout
        );

        (,, depositPrice,,,,,,,) = asyncRequests.investments(address(vault), self);
        assertEq(depositPrice, 1292307679384615384);

        // assert deposit & mint values adjusted
        assertApproxEqAbs(vault.maxDeposit(self), assets * 2, 2);
        assertEq(vault.maxMint(self), firstSharePayout + secondSharePayout);

        // collect the share class tokens
        vault.mint(firstSharePayout + secondSharePayout, self);
        assertEq(token.balanceOf(self), firstSharePayout + secondSharePayout);
    }

    function partialRedeem(uint64 poolId, bytes16 scId, AsyncVault vault, ERC20 asset) public {
        vm.assume(poolId >> 48 != THIS_CHAIN_ID);

        IShareToken token = IShareToken(address(vault.share()));

        uint128 assetId = poolManager.assetToId(address(asset), erc20TokenId);
        uint256 totalShares = token.balanceOf(self);
        uint256 redeemAmount = 50000000000000000000;
        assertTrue(redeemAmount <= totalShares);
        vault.requestRedeem(redeemAmount, self, self);

        // first trigger executed collectRedeem of the first 25 share class tokens at a price of 1.1
        uint128 firstShareRedeem = 25000000000000000000;
        uint128 secondShareRedeem = 25000000000000000000;
        assertEq(firstShareRedeem + secondShareRedeem, redeemAmount);
        uint128 firstCurrencyPayout = 27500000; // (25000000000000000000/10**18) * 10**6 * 1.1
        centrifugeChain.isFulfilledRedeemRequest(
            poolId, scId, bytes32(bytes20(self)), assetId, firstCurrencyPayout, firstShareRedeem
        );

        assertEq(vault.maxRedeem(self), firstShareRedeem);

        (,,, uint256 redeemPrice,,,,,,) = asyncRequests.investments(address(vault), self);
        assertEq(redeemPrice, 1100000000000000000);

        // second trigger executed collectRedeem of the second 25 share class tokens at a price of 1.3
        uint128 secondCurrencyPayout = 32500000; // (25000000000000000000/10**18) * 10**6 * 1.3
        centrifugeChain.isFulfilledRedeemRequest(
            poolId, scId, bytes32(bytes20(self)), assetId, secondCurrencyPayout, secondShareRedeem
        );

        (,,, redeemPrice,,,,,,) = asyncRequests.investments(address(vault), self);
        assertEq(redeemPrice, 1200000000000000000);

        assertApproxEqAbs(vault.maxWithdraw(self), firstCurrencyPayout + secondCurrencyPayout, 2);
        assertEq(vault.maxRedeem(self), redeemAmount);

        // collect the asset
        vault.redeem(redeemAmount, self, self);
        assertEq(token.balanceOf(self), totalShares - redeemAmount);
        assertEq(asset.balanceOf(self), firstCurrencyPayout + secondCurrencyPayout);
    }
}
