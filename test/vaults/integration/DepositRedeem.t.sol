// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";

contract DepositRedeem is BaseTest {
    function testPartialDepositAndRedeemExecutions(uint64 poolId, bytes16 trancheId) public {
        uint8 TRANCHE_TOKEN_DECIMALS = 18; // Like DAI
        uint8 INVESTMENT_CURRENCY_DECIMALS = 6; // 6, like USDC

        ERC20 asset = _newErc20("Currency", "CR", INVESTMENT_CURRENCY_DECIMALS);
        address vault_ =
            deployVault(poolId, TRANCHE_TOKEN_DECIMALS, restrictionManager, "", "", trancheId, address(asset), 0, 0);
        uint128 assetId = poolManager.assetToId(address(asset));
        ERC7540Vault vault = ERC7540Vault(vault_);

        centrifugeChain.updateTranchePrice(poolId, trancheId, assetId, 1000000000000000000, uint64(block.timestamp));

        partialDeposit(poolId, trancheId, vault, asset);

        partialRedeem(poolId, trancheId, vault, asset);
    }

    // Helpers

    function partialDeposit(uint64 poolId, bytes16 trancheId, ERC7540Vault vault, ERC20 asset) public {
        ITranche tranche = ITranche(address(vault.share()));

        uint256 investmentAmount = 100000000; // 100 * 10**6
        centrifugeChain.updateMember(poolId, trancheId, self, type(uint64).max);
        asset.approve(address(vault), investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        // first trigger executed collectInvest of the first 50% at a price of 1.4
        uint128 _assetId = poolManager.assetToId(address(asset)); // retrieve assetId
        uint128 assets = 50000000; // 50 * 10**6
        uint128 firstTranchePayout = 35714285714285714285; // 50 * 10**18 / 1.4, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, trancheId, bytes32(bytes20(self)), _assetId, assets, firstTranchePayout
        );

        (,, uint256 depositPrice,,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(depositPrice, 1400000000000000000);

        // second trigger executed collectInvest of the second 50% at a price of 1.2
        uint128 secondTranchePayout = 41666666666666666666; // 50 * 10**18 / 1.2, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, trancheId, bytes32(bytes20(self)), _assetId, assets, secondTranchePayout
        );

        (,, depositPrice,,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(depositPrice, 1292307679384615384);

        // assert deposit & mint values adjusted
        assertApproxEqAbs(vault.maxDeposit(self), assets * 2, 2);
        assertEq(vault.maxMint(self), firstTranchePayout + secondTranchePayout);

        // collect the tranche tokens
        vault.mint(firstTranchePayout + secondTranchePayout, self);
        assertEq(tranche.balanceOf(self), firstTranchePayout + secondTranchePayout);
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
