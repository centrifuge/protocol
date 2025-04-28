// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {MathLib} from "src/misc/libraries/MathLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";

import {PricingLib} from "src/common/libraries/PricingLib.sol";

contract PurePricingLibTest is Test {
    using PricingLib for *;
    using MathLib for uint256;

    uint8 constant MIN_ASSET_DECIMALS = 2;
    uint8 constant MAX_ASSET_DECIMALS = 18;
    uint8 constant POOL_DECIMALS = 18;
    uint8 constant SHARE_DECIMALS = POOL_DECIMALS;
    uint128 constant MIN_PRICE = 1e14;
    uint128 constant MAX_PRICE_POOL_PER_ASSET = 1e20;
    uint128 constant MAX_PRICE_POOL_PER_SHARE = 1e20;
    uint128 constant MAX_AMOUNT = type(uint128).max / MAX_PRICE_POOL_PER_SHARE;
    MathLib.Rounding constant ROUNDING_DOWN = MathLib.Rounding.Down;

    function testConvertWithPriceSameDecimals(uint128 baseAmount, uint128 priceRaw) public pure {
        baseAmount = uint128(bound(baseAmount, 0, MAX_AMOUNT));
        D18 price = d18(uint128(bound(priceRaw, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));

        uint256 expected = price.mulUint256(baseAmount, ROUNDING_DOWN);
        uint256 result = PricingLib.convertWithPrice(baseAmount, 18, 18, price);
        assertEq(result, expected);
    }

    function testConvertWithPriceDifferentDecimals(
        uint128 baseAmount,
        uint8 baseDecimals,
        uint8 quoteDecimals,
        uint128 priceRaw
    ) public pure {
        baseAmount = uint128(bound(baseAmount, 0, MAX_AMOUNT));
        baseDecimals = uint8(bound(baseDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        quoteDecimals = uint8(bound(quoteDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        D18 price = d18(uint128(bound(priceRaw, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));

        uint256 scaledBase;
        if (baseDecimals > quoteDecimals) {
            scaledBase = baseAmount / (10 ** (baseDecimals - quoteDecimals));
        } else {
            scaledBase = baseAmount * (10 ** (quoteDecimals - baseDecimals));
        }

        uint256 expected = price.mulUint256(scaledBase, ROUNDING_DOWN);
        uint256 result = PricingLib.convertWithPrice(baseAmount, baseDecimals, quoteDecimals, price);
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
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));
        D18 pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, MIN_PRICE, MAX_PRICE_POOL_PER_SHARE)));

        uint256 expectedShareAmount = pricePoolPerShare.reciprocalMulUint256(
            pricePoolPerAsset.mulUint256(
                uint256(assetAmount).mulDiv(10 ** SHARE_DECIMALS, 10 ** assetDecimals), ROUNDING_DOWN
            ),
            ROUNDING_DOWN
        );

        uint256 result = PricingLib.assetToShareAmount(
            assetAmount, assetDecimals, SHARE_DECIMALS, pricePoolPerAsset, pricePoolPerShare, ROUNDING_DOWN
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
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));
        D18 pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, MIN_PRICE, MAX_PRICE_POOL_PER_SHARE)));

        uint256 shareAmount = PricingLib.assetToShareAmount(
            assetAmount, assetDecimals, POOL_DECIMALS, pricePoolPerAsset, pricePoolPerShare, ROUNDING_DOWN
        );
        uint256 assetRoundTrip = PricingLib.shareToAssetAmount(
            shareAmount, POOL_DECIMALS, assetDecimals, pricePoolPerAsset, pricePoolPerShare, ROUNDING_DOWN
        );

        assertApproxEqAbs(
            assetRoundTrip, assetAmount, MIN_PRICE * 10, "Asset->Share->Asset roundtrip target precision excess"
        );
    }

    /// NOTE: Solely serves to represent the horrible precision for this round trip due to reciprocal multiplication
    function testShareToAssetToShareRoundTrip(
        uint128 shareAmount,
        uint8 assetDecimals,
        uint64 pricePoolPerAsset_,
        uint64 pricePoolPerShare_
    ) public pure {
        assetDecimals = uint8(bound(assetDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));
        D18 pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, MIN_PRICE, MAX_PRICE_POOL_PER_SHARE)));
        shareAmount = uint128(bound(shareAmount, 10 ** assetDecimals, MAX_AMOUNT));

        uint256 assetAmount = PricingLib.shareToAssetAmount(
            shareAmount, POOL_DECIMALS, assetDecimals, pricePoolPerAsset, pricePoolPerShare, ROUNDING_DOWN
        );
        uint256 shareRoundTrip = PricingLib.assetToShareAmount(
            assetAmount, assetDecimals, POOL_DECIMALS, pricePoolPerAsset, pricePoolPerShare, ROUNDING_DOWN
        );
        assertApproxEqAbs(
            shareRoundTrip,
            shareAmount,
            MAX_PRICE_POOL_PER_SHARE,
            "Share->Asset->Share roundtrip target precision excess"
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
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));
        D18 pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, MIN_PRICE, MAX_PRICE_POOL_PER_SHARE)));

        uint256 expectedAssetAmount = pricePoolPerAsset.reciprocalMulUint256(
            pricePoolPerShare.mulUint256(shareAmount, ROUNDING_DOWN).mulDiv(10 ** assetDecimals, 10 ** POOL_DECIMALS),
            ROUNDING_DOWN
        );

        uint256 result = PricingLib.shareToAssetAmount(
            shareAmount, POOL_DECIMALS, assetDecimals, pricePoolPerAsset, pricePoolPerShare, ROUNDING_DOWN
        );

        assertEq(result, expectedAssetAmount, "shareToAssetAmount failed");
    }

    function testPoolToAssetAmount(uint128 poolAmount, uint8 assetDecimals, uint64 pricePoolPerAsset_) public pure {
        assetDecimals = uint8(bound(assetDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        poolAmount = uint128(bound(poolAmount, 10 ** POOL_DECIMALS, MAX_AMOUNT));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));

        uint256 expectedAssetAmount = pricePoolPerAsset.reciprocalMulUint256(
            uint256(poolAmount).mulDiv(10 ** assetDecimals, 10 ** POOL_DECIMALS), ROUNDING_DOWN
        );
        uint256 result =
            PricingLib.poolToAssetAmount(poolAmount, POOL_DECIMALS, assetDecimals, pricePoolPerAsset, ROUNDING_DOWN);
        assertEq(result, expectedAssetAmount, "poolToAssetAmount failed");
    }

    // Enhanced rounding edge-case check
    function testRoundingEdgeCases() public pure {
        uint256 baseAmount = 1;
        uint8 baseDecimals = 8;
        uint8 quoteDecimals = 18;

        // Min base amount
        D18 price = d18(1e18 - 1);
        uint256 result = PricingLib.convertWithPrice(baseAmount, baseDecimals, quoteDecimals, price);
        uint256 expected = price.mulUint256(1e10, ROUNDING_DOWN);
        assertEq(result, expected, "Rounding edge case 1 (min base amount) failed");

        // Very small price
        price = d18(1e8);
        result = PricingLib.convertWithPrice(baseAmount, baseDecimals, quoteDecimals, price);
        expected = price.mulUint256(1e10, ROUNDING_DOWN);
        assertEq(result, expected, "Rounding edge case 2 (small price) failed");

        // Max baseAmount
        baseAmount = type(uint128).max;
        price = d18(type(uint64).max);
        result = PricingLib.convertWithPrice(baseAmount, baseDecimals, quoteDecimals, price);
        expected = price.mulUint256(baseAmount * (10 ** (quoteDecimals - baseDecimals)), ROUNDING_DOWN);
        assertEq(result, expected, "Rounding edge case 3 (max baseAmount) failed");
    }
}
