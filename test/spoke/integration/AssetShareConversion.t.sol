// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "./BaseTest.sol";

contract AssetShareConversionTest is BaseTest {
    function testAssetShareConversion(bytes16 scId) public {
        uint8 INVESTMENT_CURRENCY_DECIMALS = 6; // 6, like USDC
        uint8 SHARE_TOKEN_DECIMALS = 18; // Like DAI

        ERC20 asset = _newErc20("Asset", "A", INVESTMENT_CURRENCY_DECIMALS);
        (uint64 poolId, address vault_, uint128 assetId) = deployVault(
            VaultKind.Async, SHARE_TOKEN_DECIMALS, address(fullRestrictionsHook), scId, address(asset), 0, 0
        );
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));

        assertEq(vault.priceLastUpdated(), block.timestamp);
        assertEq(vault.pricePerShare(), 1e6);
        centrifugeChain.updatePricePoolPerShare(poolId, scId, 1e18, uint64(block.timestamp));
        centrifugeChain.updatePricePoolPerAsset(poolId, scId, assetId, 1e18, uint64(block.timestamp));
        assertEq(vault.priceLastUpdated(), uint64(block.timestamp));
        assertEq(vault.pricePerShare(), 1e6);

        // invest
        uint256 investmentAmount = 100000000; // 100 * 10**6
        centrifugeChain.updateMember(poolId, scId, self, type(uint64).max);
        asset.approve(vault_, investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        assertEq(asset.balanceOf(address(globalEscrow)), investmentAmount);

        // trigger executed collectInvest at a price of 1.0
        uint128 shares = 100000000000000000000; // 100 * 10**18
        centrifugeChain.isFulfilledDepositRequest(
            poolId, scId, bytes32(bytes20(self)), assetId, uint128(investmentAmount), shares, 0
        );
        vault.mint(shares, self);
        centrifugeChain.updatePricePoolPerShare(poolId, scId, 1e18, uint64(block.timestamp));
        // assert share/asset conversion
        assertEq(shareToken.totalSupply(), 100000000000000000000);
        assertEq(vault.totalAssets(), 100000000);
        assertEq(vault.convertToShares(100000000), 100000000000000000000); // share class tokens have 12 more decimals
            // than
            // assets
        assertEq(vault.convertToAssets(vault.convertToShares(100000000000000000000)), 100000000000000000000);
        assertEq(vault.pricePerShare(), 1e6);

        // assert share/asset conversion after price update
        centrifugeChain.updatePricePoolPerShare(poolId, scId, 1200000000000000000, uint64(block.timestamp));

        assertEq(vault.totalAssets(), 120000000);
        assertEq(vault.convertToShares(120000000), 100000000000000000000); // share class tokens have 12 more decimals
            // than
            // assets
        assertEq(vault.convertToAssets(vault.convertToShares(120000000000000000000)), 120000000000000000000);
        assertEq(vault.pricePerShare(), 1.2e6);

        // Updating the asset price updates the conversions and price per share in asset
        centrifugeChain.updatePricePoolPerAsset(poolId, scId, assetId, 0.5e18, uint64(block.timestamp));

        // NOTE: For 1 unit of pool, you know get 2 units of assets. As the price of a share is 1.2 POOL/SHARE
        //       we now have 2 * 1.2 = 2.4 units of assets per share
        assertEq(vault.totalAssets(), 240000000);
        assertEq(vault.convertToShares(240000000), 100000000000000000000); // share class tokens have 12 more decimals
            // than
        // assets
        assertEq(vault.convertToAssets(vault.convertToShares(240000000000000000000)), 240000000000000000000);
        assertEq(vault.pricePerShare(), 2.4e6);
    }

    function testAssetShareConversionWithInverseDecimals(bytes16 scId) public {
        uint8 INVESTMENT_CURRENCY_DECIMALS = 18; // 18, like DAI
        uint8 SHARE_TOKEN_DECIMALS = 6; // Like USDC

        ERC20 asset = _newErc20("Currency", "CR", INVESTMENT_CURRENCY_DECIMALS);
        (uint64 poolId, address vault_, uint128 assetId) = deployVault(
            VaultKind.Async, SHARE_TOKEN_DECIMALS, address(fullRestrictionsHook), scId, address(asset), 0, 0
        );
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));
        centrifugeChain.updatePricePoolPerShare(poolId, scId, 1000000, uint64(block.timestamp));

        // invest
        uint256 investmentAmount = 100000000000000000000; // 100 * 10**18
        centrifugeChain.updateMember(poolId, scId, self, type(uint64).max);
        asset.approve(vault_, investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        // trigger executed collectInvest at a price of 1.0
        uint128 shares = 100000000; // 100 * 10**6
        centrifugeChain.isFulfilledDepositRequest(
            poolId, scId, bytes32(bytes20(self)), assetId, uint128(investmentAmount), shares, 0
        );
        vault.mint(shares, self);
        centrifugeChain.updatePricePoolPerShare(poolId, scId, 1000000000000000000, uint64(block.timestamp));

        // assert share/asset conversion
        assertEq(shareToken.totalSupply(), 100000000);
        assertEq(vault.totalAssets(), 100000000000000000000);
        // share class tokens have 12 less decimals than asset
        assertEq(vault.convertToShares(100000000000000000000), 100000000);
        assertEq(vault.convertToAssets(vault.convertToShares(100000000000000000000)), 100000000000000000000);
        assertEq(vault.pricePerShare(), 1e18);

        // assert share/asset conversion after price update
        centrifugeChain.updatePricePoolPerShare(poolId, scId, 1200000000000000000, uint64(block.timestamp));

        assertEq(vault.totalAssets(), 120000000000000000000);
        // share class tokens have 12 less decimals than assets
        assertEq(vault.convertToShares(120000000000000000000), 100000000);
        assertEq(vault.convertToAssets(vault.convertToShares(120000000000000000000)), 120000000000000000000);
        assertEq(vault.pricePerShare(), 1.2e18);
    }

    function testPriceWorksAfterRemovingVault(bytes16 scId) public {
        uint8 INVESTMENT_CURRENCY_DECIMALS = 6; // 6, like USDC
        uint8 SHARE_TOKEN_DECIMALS = 18; // Like DAI

        ERC20 asset = _newErc20("Asset", "A", INVESTMENT_CURRENCY_DECIMALS);
        (uint64 poolId, address vault_, uint128 assetId) = deployVault(
            VaultKind.Async, SHARE_TOKEN_DECIMALS, address(fullRestrictionsHook), scId, address(asset), 0, 0
        );
        AsyncVault vault = AsyncVault(vault_);
        IShareToken(address(vault.share()));

        assertEq(vault.priceLastUpdated(), block.timestamp);
        assertEq(vault.pricePerShare(), 1e6);
        centrifugeChain.updatePricePoolPerShare(poolId, scId, 1.2e18, uint64(block.timestamp));
        assertEq(vault.priceLastUpdated(), uint64(block.timestamp));
        assertEq(vault.pricePerShare(), 1.2e6);

        spoke.unlinkVault(PoolId.wrap(poolId), ShareClassId.wrap(scId), AssetId.wrap(assetId), vault);

        assertEq(vault.priceLastUpdated(), uint64(block.timestamp));
        assertEq(vault.pricePerShare(), 1.2e6);
    }
}
