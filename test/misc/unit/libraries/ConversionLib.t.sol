// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {ConversionLib} from "src/misc/libraries/ConversionLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";

contract ConversionLibFuzzTest is Test {
    using ConversionLib for *;

    uint8 constant MIN_ASSET_DECIMALS = 2;
    uint8 constant MAX_ASSET_DECIMALS = 18;
    uint8 constant POOL_DECIMALS = 18;
    uint8 constant SHARE_DECIMALS = POOL_DECIMALS;
    uint128 constant MIN_PRICE = 1e10;
    uint128 constant MAX_PRICE = 1e20;
    uint128 constant MAX_AMOUNT = type(uint128).max / MAX_PRICE;

    function testConvertWithPriceSameDecimals(uint128 baseAmount, uint128 priceRaw) public pure {
        D18 price = d18(priceRaw);
        uint256 expected = price.mulUint256(baseAmount);
        uint256 result = ConversionLib.convertWithPrice(baseAmount, 18, 18, price);
        assertEq(result, expected);
    }

    function testConvertWithPriceDifferentDecimals(
        uint128 baseAmount,
        uint8 baseDecimals,
        uint8 quoteDecimals,
        uint128 priceRaw
    ) public pure {
        baseDecimals = uint8(bound(baseDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        quoteDecimals = uint8(bound(quoteDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));

        D18 price = d18(priceRaw);
        uint256 scaledBase;
        if (baseDecimals > quoteDecimals) {
            scaledBase = baseAmount / (10 ** (baseDecimals - quoteDecimals));
        } else {
            scaledBase = baseAmount * (10 ** (quoteDecimals - baseDecimals));
        }

        uint256 expected = price.mulUint256(scaledBase);
        uint256 result = ConversionLib.convertWithPrice(baseAmount, baseDecimals, quoteDecimals, price);
        assertEq(result, expected);
    }

    function testAssetToShareAmount(
        uint128 assetAmount,
        uint8 assetDecimals,
        uint128 pricePoolPerAsset_,
        uint128 pricePoolPerShare_
    ) public pure {
        assetDecimals = uint8(bound(assetDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        assetAmount = uint128(bound(assetAmount, 10 ** assetDecimals, MAX_AMOUNT));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, MIN_PRICE, MAX_PRICE)));
        D18 pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, MIN_PRICE, MAX_PRICE)));

        uint256 poolAmount =
            ConversionLib.convertWithPrice(assetAmount, assetDecimals, SHARE_DECIMALS, pricePoolPerAsset);
        uint256 expectedShareAmount = pricePoolPerShare.reciprocalMulUint256(poolAmount);

        uint256 result = ConversionLib.assetToShareAmount(
            assetAmount, assetDecimals, SHARE_DECIMALS, pricePoolPerAsset, pricePoolPerShare
        );
        
        assertEq(result, expectedShareAmount, "assetToShareAmount failed");
    }

    function testAssetToShareToAssetRoundTrip(
        uint128 assetAmount,
        uint8 assetDecimals,
        uint64 pricePoolPerAsset_,
        uint64 pricePoolPerShare_
    ) public pure {
        assetDecimals = uint8(bound(assetDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        assetAmount = uint128(bound(assetAmount, 10 ** assetDecimals, MAX_AMOUNT));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, MIN_PRICE, MAX_PRICE)));
        D18 pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, MIN_PRICE, MAX_PRICE)));

        uint256 shareAmount = ConversionLib.assetToShareAmount(
            assetAmount, assetDecimals, POOL_DECIMALS, pricePoolPerAsset, pricePoolPerShare
        );
        uint256 assetRoundTrip = ConversionLib.shareToAssetAmount(
            shareAmount, POOL_DECIMALS, assetDecimals, pricePoolPerShare, pricePoolPerAsset
        );

        assertApproxEqAbs(assetRoundTrip, assetAmount, MIN_PRICE * 10, "Asset->Share->Asset roundtrip target precision excess");
    }

    /// NOTE: Solely serves to represent the horrible precision for this round trip due to reciprocal multiplication
    function testShareToAssetToShareRoundTrip(
        uint128 shareAmount,
        uint8 assetDecimals,
        uint64 pricePoolPerAsset_,
        uint64 pricePoolPerShare_
    ) public pure {
        assetDecimals = uint8(bound(assetDecimals, 6, MAX_ASSET_DECIMALS));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, MIN_PRICE, MAX_PRICE)));
        D18 pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, 1e14, MAX_PRICE)));
        shareAmount = uint128(bound(shareAmount, 10 ** assetDecimals, type(uint128).max / pricePoolPerShare.inner()));

        uint256 assetAmount = ConversionLib.shareToAssetAmount(
            shareAmount, POOL_DECIMALS, assetDecimals, pricePoolPerShare, pricePoolPerAsset
        );
        uint256 shareRoundTrip = ConversionLib.assetToShareAmount(
            assetAmount, assetDecimals, POOL_DECIMALS, pricePoolPerAsset, pricePoolPerShare
        );
        assertApproxEqAbs(
            shareRoundTrip, shareAmount, MAX_PRICE, "Share->Asset->Share roundtrip target precision excess"
        );
    }

    function testShareToAssetAmount(
        uint128 shareAmount,
        uint8 assetDecimals,
        uint64 pricePoolPerShare_,
        uint64 pricePoolPerAsset_
    ) public pure {
        assetDecimals = uint8(bound(assetDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        shareAmount = uint128(bound(shareAmount, 1e18, MAX_AMOUNT));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, MIN_PRICE, MAX_PRICE)));
        D18 pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, MIN_PRICE, MAX_PRICE)));

        uint256 poolAmount = pricePoolPerShare.mulUint256(shareAmount);
        uint256 assetAmount =
            ConversionLib.convertWithPrice(poolAmount, POOL_DECIMALS, assetDecimals, pricePoolPerAsset.reciprocal());

        uint256 result = ConversionLib.shareToAssetAmount(
            shareAmount, POOL_DECIMALS, assetDecimals, pricePoolPerShare, pricePoolPerAsset
        );

        assertEq(result, assetAmount, "shareToAssetAmount failed");
    }

    function testPoolToAssetAmount(uint128 poolAmount, uint8 assetDecimals, uint64 pricePoolPerAsset_) public pure {
        assetDecimals = uint8(bound(assetDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        poolAmount = uint128(bound(poolAmount, 10 ** POOL_DECIMALS, MAX_AMOUNT));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, MIN_PRICE, MAX_PRICE)));

        uint256 expectedAssetAmount =
            ConversionLib.convertWithPrice(poolAmount, POOL_DECIMALS, assetDecimals, pricePoolPerAsset.reciprocal());
        uint256 result = ConversionLib.poolToAssetAmount(poolAmount, POOL_DECIMALS, assetDecimals, pricePoolPerAsset);
        assertEq(result, expectedAssetAmount, "poolToAssetAmount failed");
    }

    // Enhanced rounding edge-case check
    function testRoundingEdgeCases() public pure {
        uint256 baseAmount = 1;
        uint8 baseDecimals = 8;
        uint8 quoteDecimals = 18;

        // Min base amount
        D18 price = d18(1e18 - 1);
        uint256 result = ConversionLib.convertWithPrice(baseAmount, baseDecimals, quoteDecimals, price);
        uint256 expected = price.mulUint256(1e10);
        assertEq(result, expected, "Rounding edge case 1 (min base amount) failed");

        // Very small price
        price = d18(1);
        result = ConversionLib.convertWithPrice(baseAmount, baseDecimals, quoteDecimals, price);
        expected = price.mulUint256(1e10);
        assertEq(result, expected, "Rounding edge case 2 (small price) failed");

        // Max baseAmount
        baseAmount = type(uint128).max;
        price = d18(type(uint64).max);
        result = ConversionLib.convertWithPrice(baseAmount, baseDecimals, quoteDecimals, price);
        expected = price.mulUint256(baseAmount * (10 ** (quoteDecimals - baseDecimals)));
        assertEq(result, expected, "Rounding edge case 3 (max baseAmount) failed");
    }
}
