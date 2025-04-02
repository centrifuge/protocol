// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";

contract AssetShareConversionTest is BaseTest {
    function testAssetShareConversion(uint64 poolId, bytes16 trancheId) public {
        vm.assume(poolId >> 48 != THIS_CHAIN_ID);

        uint8 INVESTMENT_CURRENCY_DECIMALS = 6; // 6, like USDC
        uint8 TRANCHE_TOKEN_DECIMALS = 18; // Like DAI

        ERC20 asset = _newErc20("Asset", "A", INVESTMENT_CURRENCY_DECIMALS);
        (address vault_, uint128 assetId) = deployVault(
            VaultKind.Async, poolId, TRANCHE_TOKEN_DECIMALS, restrictionManager, "", "", trancheId, address(asset), 0, 0
        );
        AsyncVault vault = AsyncVault(vault_);
        ITranche tranche = ITranche(address(AsyncVault(vault_).share()));

        assertEq(vault.priceLastUpdated(), block.timestamp);
        assertEq(vault.pricePerShare(), 1e6);
        centrifugeChain.updateTranchePrice(poolId, trancheId, 1e18, uint64(block.timestamp));
        centrifugeChain.updateAssetPrice(poolId, trancheId, assetId, 1e18, uint64(block.timestamp));
        assertEq(vault.priceLastUpdated(), uint64(block.timestamp));
        assertEq(vault.pricePerShare(), 1e6);

        // invest
        uint256 investmentAmount = 100000000; // 100 * 10**6
        centrifugeChain.updateMember(poolId, trancheId, self, type(uint64).max);
        asset.approve(vault_, investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        // trigger executed collectInvest at a price of 1.0
        uint128 _assetId = poolManager.assetToId(address(asset), erc20TokenId); // retrieve assetId
        uint128 shares = 100000000000000000000; // 100 * 10**18
        centrifugeChain.isFulfilledDepositRequest(
            poolId, trancheId, bytes32(bytes20(self)), _assetId, uint128(investmentAmount), shares
        );
        vault.mint(shares, self);
        centrifugeChain.updateTranchePrice(poolId, trancheId, 1e18, uint64(block.timestamp));
        // assert share/asset conversion
        assertEq(tranche.totalSupply(), 100000000000000000000);
        assertEq(vault.totalAssets(), 100000000);
        assertEq(vault.convertToShares(100000000), 100000000000000000000); // tranche tokens have 12 more decimals than
            // assets
        assertEq(vault.convertToAssets(vault.convertToShares(100000000000000000000)), 100000000000000000000);
        assertEq(vault.pricePerShare(), 1e6);

        // assert share/asset conversion after price update
        centrifugeChain.updateTranchePrice(poolId, trancheId, 1200000000000000000, uint64(block.timestamp));

        assertEq(vault.totalAssets(), 120000000);
        assertEq(vault.convertToShares(120000000), 100000000000000000000); // tranche tokens have 12 more decimals than
            // assets
        assertEq(vault.convertToAssets(vault.convertToShares(120000000000000000000)), 120000000000000000000);
        assertEq(vault.pricePerShare(), 1.2e6);


        // Updating the asset price updates the conversions and price per share in asset
        centrifugeChain.updateAssetPrice(poolId, trancheId, assetId, 0.5e18, uint64(block.timestamp));

        // NOTE: For 1 unit of pool, you know get 2 units of assets. As the price of a share is 1.2 POOL/SHARE
        //       we now have 2 * 1.2 = 2.4 units of assets per share
        assertEq(vault.totalAssets(), 240000000);
        assertEq(vault.convertToShares(240000000), 100000000000000000000); // tranche tokens have 12 more decimals than
        // assets
        assertEq(vault.convertToAssets(vault.convertToShares(240000000000000000000)), 240000000000000000000);
        assertEq(vault.pricePerShare(), 2.4e6);
    }

    function testAssetShareConversionWithInverseDecimals(uint64 poolId, bytes16 trancheId) public {
        vm.assume(poolId >> 48 != THIS_CHAIN_ID);

        uint8 INVESTMENT_CURRENCY_DECIMALS = 18; // 18, like DAI
        uint8 TRANCHE_TOKEN_DECIMALS = 6; // Like USDC

        ERC20 asset = _newErc20("Currency", "CR", INVESTMENT_CURRENCY_DECIMALS);
        (address vault_, ) = deployVault(
            VaultKind.Async, poolId, TRANCHE_TOKEN_DECIMALS, restrictionManager, "", "", trancheId, address(asset), 0, 0
        );
        AsyncVault vault = AsyncVault(vault_);
        ITranche tranche = ITranche(address(AsyncVault(vault_).share()));
        centrifugeChain.updateTranchePrice(poolId, trancheId, 1000000, uint64(block.timestamp));

        // invest
        uint256 investmentAmount = 100000000000000000000; // 100 * 10**18
        centrifugeChain.updateMember(poolId, trancheId, self, type(uint64).max);
        asset.approve(vault_, investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        // trigger executed collectInvest at a price of 1.0
        uint128 _assetId = poolManager.assetToId(address(asset), erc20TokenId); // retrieve assetId
        uint128 shares = 100000000; // 100 * 10**6
        centrifugeChain.isFulfilledDepositRequest(
            poolId, trancheId, bytes32(bytes20(self)), _assetId, uint128(investmentAmount), shares
        );
        vault.mint(shares, self);
        centrifugeChain.updateTranchePrice(poolId, trancheId, 1000000000000000000, uint64(block.timestamp));

        // assert share/asset conversion
        assertEq(tranche.totalSupply(), 100000000);
        assertEq(vault.totalAssets(), 100000000000000000000);
        // tranche tokens have 12 less decimals than asset
        assertEq(vault.convertToShares(100000000000000000000), 100000000);
        assertEq(vault.convertToAssets(vault.convertToShares(100000000000000000000)), 100000000000000000000);
        assertEq(vault.pricePerShare(), 1e18);

        // assert share/asset conversion after price update
        centrifugeChain.updateTranchePrice(poolId, trancheId, 1200000000000000000, uint64(block.timestamp));

        assertEq(vault.totalAssets(), 120000000000000000000);
        // tranche tokens have 12 less decimals than assets
        assertEq(vault.convertToShares(120000000000000000000), 100000000);
        assertEq(vault.convertToAssets(vault.convertToShares(120000000000000000000)), 120000000000000000000);
        assertEq(vault.pricePerShare(), 1.2e18);
    }

    function testPriceWorksAfterRemovingVault(uint64 poolId, bytes16 trancheId) public {
        vm.assume(poolId >> 48 != THIS_CHAIN_ID);

        uint8 INVESTMENT_CURRENCY_DECIMALS = 6; // 6, like USDC
        uint8 TRANCHE_TOKEN_DECIMALS = 18; // Like DAI

        ERC20 asset = _newErc20("Asset", "A", INVESTMENT_CURRENCY_DECIMALS);
        (address vault_, uint128 assetId) = deployVault(
            VaultKind.Async, poolId, TRANCHE_TOKEN_DECIMALS, restrictionManager, "", "", trancheId, address(asset), 0, 0
        );
        AsyncVault vault = AsyncVault(vault_);
        ITranche(address(AsyncVault(vault_).share()));

        assertEq(vault.priceLastUpdated(), block.timestamp);
        assertEq(vault.pricePerShare(), 1e6);
        centrifugeChain.updateTranchePrice(poolId, trancheId, 1.2e18, uint64(block.timestamp));
        assertEq(vault.priceLastUpdated(), uint64(block.timestamp));
        assertEq(vault.pricePerShare(), 1.2e6);

        poolManager.unlinkVault(poolId, trancheId, assetId, address(vault));

        assertEq(vault.priceLastUpdated(), uint64(block.timestamp));
        assertEq(vault.pricePerShare(), 1.2e6);
    }
}
