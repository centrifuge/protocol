// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {MathLib} from "src/misc/libraries/MathLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC20Metadata} from "src/misc/interfaces/IERC20.sol";

import {PricingLib} from "src/common/libraries/PricingLib.sol";

contract PricingLibBaseTest is Test {
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
}

contract ConvertWithPriceTest is PricingLibBaseTest {
    using PricingLib for *;
    using MathLib for uint256;

    function testConvertWithPriceSimple() public pure {
        uint8 baseDecimals = 2;
        uint8 quoteDecimals = 18;
        uint128 baseAmount = 4e10;
        D18 priceQuotePerBase = d18(2e10);

        uint256 expected = priceQuotePerBase.inner() * baseAmount * 10 ** (quoteDecimals - baseDecimals) / 1e18;

        assertEq(expected, 8e18);
        assertEq(
            PricingLib.convertWithPrice(
                baseAmount, baseDecimals, quoteDecimals, priceQuotePerBase, MathLib.Rounding.Down
            ),
            expected
        );
    }

    function testConvertWithPriceSameDecimals(uint128 baseAmount, uint128 priceRaw) public pure {
        baseAmount = uint128(bound(baseAmount, 0, MAX_AMOUNT));
        D18 price = d18(uint128(bound(priceRaw, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));

        uint256 expected = price.mulUint256(baseAmount, MathLib.Rounding.Down);
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

        uint256 underestimate = price.mulUint256(scaledBase, MathLib.Rounding.Down);
        uint256 expectedDown = MathLib.mulDiv(
            baseAmount * 10 ** quoteDecimals, price.inner(), 10 ** baseDecimals * 1e18, MathLib.Rounding.Down
        );
        uint256 expectedUp = MathLib.mulDiv(
            baseAmount * 10 ** quoteDecimals, price.inner(), 10 ** baseDecimals * 1e18, MathLib.Rounding.Up
        );
        uint256 result = PricingLib.convertWithPrice(baseAmount, baseDecimals, quoteDecimals, price);

        assertGe(result, underestimate, "convertWithPrice should be at least as large as underestimate");
        assertEq(result, expectedDown, "convertWithPrice failed");
        assertApproxEqAbs(expectedDown, expectedUp, 1, "Rounding diff should be at most one");
    }
}

contract ConvertWithPriceEdgeCasesTest is PricingLibBaseTest {
    uint256 baseAmount = 1;
    uint8 baseDecimals = 8;
    uint8 quoteDecimals = 18;
    uint128 amountWithoutPrice = 1e10; // 1e18/1e8

    function testEdgeCaseWithPriceMinBaseAmount() public view {
        D18 price = d18(1e18 - 1);
        uint256 result = PricingLib.convertWithPrice(baseAmount, baseDecimals, quoteDecimals, price);
        uint256 expected = price.mulUint256(amountWithoutPrice, MathLib.Rounding.Down);
        assertEq(result, expected);
        assertEq(expected, amountWithoutPrice - 1);
    }

    function testEdgeCaseWithPriceSmallestPriceToResultInOne() public view {
        D18 price = d18(1e18 / amountWithoutPrice);
        uint256 result = PricingLib.convertWithPrice(baseAmount, baseDecimals, quoteDecimals, price);
        assertEq(result, 1);
    }

    function testEdgeCaseWithPriceSmallestPriceToResultInZero() public view {
        D18 price = d18(1e18 / amountWithoutPrice - 1);
        uint256 result = PricingLib.convertWithPrice(baseAmount, baseDecimals, quoteDecimals, price);
        assertEq(result, 0);
    }

    function testEdgeCaseWithPriceMaxAmounts() public view {
        uint256 maxBaseAmount = type(uint128).max;
        D18 price = d18(type(uint64).max);
        uint256 result = PricingLib.convertWithPrice(maxBaseAmount, baseDecimals, quoteDecimals, price);
        uint256 expected =
            price.mulUint256(maxBaseAmount * (10 ** (quoteDecimals - baseDecimals)), MathLib.Rounding.Down);
        assertEq(result, expected);
    }

    function testEdgeCaseWithPriceZeroPrice() public pure {
        uint256 result = PricingLib.convertWithPrice(1e18, 18, 18, d18(0), MathLib.Rounding.Down);
        assertEq(result, 0);
    }
}

contract ConvertWithReciprocalPriceTest is PricingLibBaseTest {
    using PricingLib for *;
    using MathLib for uint256;

    function testConvertWithReciprocalPriceSimple() public pure {
        uint8 baseDecimals = 2;
        uint8 quoteDecimals = 18;
        uint128 baseAmount = 8e10;
        D18 priceBasePerQuote = d18(2e10);

        uint256 expected = baseAmount * 10 ** quoteDecimals * 1e18 / (10 ** baseDecimals * priceBasePerQuote.inner());

        assertEq(expected, 4e34);
        assertEq(
            PricingLib.convertWithReciprocalPrice(
                baseAmount, baseDecimals, quoteDecimals, priceBasePerQuote, MathLib.Rounding.Down
            ),
            expected
        );
    }

    function testConvertWithReciprocalPriceSameDecimals(uint128 baseAmount, uint128 priceRaw) public pure {
        baseAmount = uint128(bound(baseAmount, 0, MAX_AMOUNT));
        D18 price = d18(uint128(bound(priceRaw, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));

        uint256 expected = price.reciprocalMulUint256(baseAmount, MathLib.Rounding.Down);
        uint256 result = PricingLib.convertWithReciprocalPrice(baseAmount, 18, 18, price, MathLib.Rounding.Down);
        assertEq(result, expected);
    }

    function testConvertWithReciprocalPriceDifferentDecimals(
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

        uint256 underestimate = price.reciprocalMulUint256(scaledBase, MathLib.Rounding.Down);
        uint256 expectedDown = MathLib.mulDiv(
            baseAmount * 10 ** quoteDecimals, 1e18, 10 ** baseDecimals * price.inner(), MathLib.Rounding.Down
        );
        uint256 expectedUp = MathLib.mulDiv(
            baseAmount * 10 ** quoteDecimals, 1e18, 10 ** baseDecimals * price.inner(), MathLib.Rounding.Up
        );
        uint256 result =
            PricingLib.convertWithReciprocalPrice(baseAmount, baseDecimals, quoteDecimals, price, MathLib.Rounding.Down);

        assertGe(result, underestimate, "convertWithReciprocalPrice should be at least as large as underestimate");
        assertEq(result, expectedDown, "convertWithReciprocalPrice failed");
        assertApproxEqAbs(expectedDown, expectedUp, 1, "Rounding diff should be at most one");
    }
}

contract ConvertWithReciprocalPriceEdgeCasesTest is PricingLibBaseTest {
    uint256 baseAmount = 1;
    uint8 baseDecimals = 8;
    uint8 quoteDecimals = 18;
    uint128 amountWithoutPrice = 1e10; // 1e18/1e8

    function testEdgeCaseWithReciprocalPriceMinBaseAmount() public view {
        D18 price = d18(1e18 - 1);
        uint256 result =
            PricingLib.convertWithReciprocalPrice(baseAmount, baseDecimals, quoteDecimals, price, MathLib.Rounding.Down);
        uint256 expected = price.reciprocalMulUint256(amountWithoutPrice, MathLib.Rounding.Down);
        assertEq(result, expected);
        assertEq(expected, amountWithoutPrice);
    }

    function testEdgeCaseWithReciprocalPriceSmallestPrice() public view {
        D18 price = d18(1);
        uint256 result =
            PricingLib.convertWithReciprocalPrice(baseAmount, baseDecimals, quoteDecimals, price, MathLib.Rounding.Down);
        uint256 expected = price.reciprocalMulUint256(amountWithoutPrice, MathLib.Rounding.Down);
        assertEq(result, expected);
        assertEq(expected, 1e28);
    }

    function testEdgeCaseWithReciprocalPriceSmallestPriceToZero() public view {
        D18 price = d18(1e28 + 1);
        uint256 result =
            PricingLib.convertWithReciprocalPrice(baseAmount, baseDecimals, quoteDecimals, price, MathLib.Rounding.Down);
        assertEq(result, 0, "Reciprocal rounding edge case (smallest price to result in 0) failed");

        price = d18(1e28);
        result =
            PricingLib.convertWithReciprocalPrice(baseAmount, baseDecimals, quoteDecimals, price, MathLib.Rounding.Down);
        assertEq(result, 1, "Reciprocal rounding edge case (smallest price to result in 1) failed");
    }

    function testEdgeCaseWithReciprocalPriceMaxAmounts() public view {
        uint256 maxBaseAmount = type(uint128).max;
        D18 price = d18(type(uint64).max);
        uint256 result = PricingLib.convertWithReciprocalPrice(
            maxBaseAmount, baseDecimals, quoteDecimals, price, MathLib.Rounding.Down
        );
        uint256 expected =
            price.reciprocalMulUint256(maxBaseAmount * (10 ** (quoteDecimals - baseDecimals)), MathLib.Rounding.Down);
        assertEq(result, expected);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testEdgeCaseWithReciprocalPriceZeroPrice() public {
        vm.expectRevert(bytes("PricingLib/division-by-zero"));
        PricingLib.convertWithReciprocalPrice(1e18, 18, 18, d18(0), MathLib.Rounding.Down);
    }
}

contract ConvertWithPricesTest is PricingLibBaseTest {
    using PricingLib for *;
    using MathLib for uint256;

    function testConvertWithPricesSimple() public pure {
        uint8 baseDecimals = 2;
        uint8 quoteDecimals = 18;
        uint128 baseAmount = 4e10;
        D18 priceNumerator = d18(2e10);
        D18 priceDenominator = d18(8e10);

        uint256 expected =
            priceNumerator.inner() * baseAmount * 10 ** quoteDecimals / (10 ** baseDecimals * priceDenominator.inner());

        assertEq(expected, 1e26);
        assertEq(
            PricingLib.convertWithPrices(
                baseAmount, baseDecimals, quoteDecimals, priceNumerator, priceDenominator, MathLib.Rounding.Down
            ),
            expected
        );
    }

    function testConvertWithPricesSameDecimals(
        uint128 baseAmount,
        uint128 priceNumeratorRaw,
        uint128 priceDenominatorRaw
    ) public pure {
        baseAmount = uint128(bound(baseAmount, 0, MAX_AMOUNT));
        D18 priceNumerator = d18(uint128(bound(priceNumeratorRaw, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));
        D18 priceDenominator = d18(uint128(bound(priceDenominatorRaw, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));

        uint256 expected =
            MathLib.mulDiv(priceNumerator.inner(), baseAmount, priceDenominator.inner(), MathLib.Rounding.Down);
        uint256 result =
            PricingLib.convertWithPrices(baseAmount, 18, 18, priceNumerator, priceDenominator, MathLib.Rounding.Down);
        assertEq(result, expected);
    }

    function testConvertWithPricesDifferentDecimals(
        uint128 baseAmount,
        uint8 baseDecimals,
        uint8 quoteDecimals,
        uint128 priceNumeratorRaw,
        uint128 priceDenominatorRaw
    ) public pure {
        baseAmount = uint128(bound(baseAmount, 0, MAX_AMOUNT));
        baseDecimals = uint8(bound(baseDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        quoteDecimals = uint8(bound(quoteDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        D18 priceNumerator = d18(uint128(bound(priceNumeratorRaw, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));
        D18 priceDenominator = d18(uint128(bound(priceDenominatorRaw, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));

        uint256 scaledBase;
        if (baseDecimals > quoteDecimals) {
            scaledBase = baseAmount / (10 ** (baseDecimals - quoteDecimals));
        } else {
            scaledBase = baseAmount * (10 ** (quoteDecimals - baseDecimals));
        }

        uint256 underestimate =
            MathLib.mulDiv(priceNumerator.inner(), scaledBase, priceDenominator.inner(), MathLib.Rounding.Down);
        uint256 expectedDown = MathLib.mulDiv(
            priceNumerator.inner(),
            baseAmount * 10 ** quoteDecimals,
            10 ** baseDecimals * priceDenominator.inner(),
            MathLib.Rounding.Down
        );
        uint256 expectedUp = MathLib.mulDiv(
            priceNumerator.inner(),
            baseAmount * 10 ** quoteDecimals,
            10 ** baseDecimals * priceDenominator.inner(),
            MathLib.Rounding.Up
        );
        uint256 result = PricingLib.convertWithPrices(
            baseAmount, baseDecimals, quoteDecimals, priceNumerator, priceDenominator, MathLib.Rounding.Down
        );

        assertGe(result, underestimate, "convertWithPrices should be at least as large as underestimate");
        assertEq(result, expectedDown, "convertWithPrices failed");
        assertApproxEqAbs(expectedDown, expectedUp, 1, "Rounding diff should be at most one");
    }
}

contract ConvertWithPricesEdgeCasesTest is PricingLibBaseTest {
    uint256 baseAmount = 1;
    uint8 baseDecimals = 8;
    uint8 quoteDecimals = 18;
    uint128 amountWithoutPrice = 1e10; // 1e18/1e8

    function testEdgeCaseWithPricesMinBaseAmount() public view {
        D18 priceLower = d18(1e18 - 1);
        D18 priceHigher = d18(1e18);
        uint256 result = PricingLib.convertWithPrices(
            baseAmount, baseDecimals, quoteDecimals, priceLower, priceHigher, MathLib.Rounding.Down
        );
        assertEq(result, amountWithoutPrice - 1, "Lower price in numerator failed");

        result = PricingLib.convertWithPrices(
            baseAmount, baseDecimals, quoteDecimals, priceHigher, priceLower, MathLib.Rounding.Down
        );
        assertEq(result, amountWithoutPrice, "Lower price in denominator failed");
    }

    function testEdgeCaseWithPricesTinyNumerator() public view {
        D18 priceNumerator = d18(1);
        D18 priceDenominator = d18(1e10);
        uint256 result = PricingLib.convertWithPrices(
            baseAmount, baseDecimals, quoteDecimals, priceNumerator, priceDenominator, MathLib.Rounding.Down
        );
        uint256 expected = amountWithoutPrice / priceDenominator.raw();
        assertEq(result, expected);
        assertEq(expected, 1);
    }

    function testEdgeCaseWithPricesTinyDenominator() public view {
        D18 priceNumerator = d18(1e9);
        D18 priceDenominator = d18(1);
        uint256 result = PricingLib.convertWithPrices(
            baseAmount, baseDecimals, quoteDecimals, priceNumerator, priceDenominator, MathLib.Rounding.Down
        );
        uint256 expected = priceNumerator.raw() * amountWithoutPrice;
        assertEq(result, expected);
        assertEq(expected, 1e19);
    }

    function testEdgeCaseWithPricesMaxAmounts() public view {
        uint256 maxBaseAmount = type(uint128).max;

        D18 priceNumerator = d18(type(uint64).max);
        D18 priceDenominator = d18(type(uint64).max);
        uint256 result = PricingLib.convertWithPrices(
            maxBaseAmount, baseDecimals, quoteDecimals, priceNumerator, priceDenominator, MathLib.Rounding.Down
        );
        assertEq(result, uint256(amountWithoutPrice * maxBaseAmount));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testConvertWithPricesZeroPrices() public {
        uint256 resultNumZero = PricingLib.convertWithPrices(1e18, 18, 18, d18(0), d18(1e18), MathLib.Rounding.Down);
        assertEq(resultNumZero, 0);

        vm.expectRevert(bytes("PricingLib/division-by-zero"));
        PricingLib.convertWithPrices(1e18, 18, 18, d18(1e18), d18(0), MathLib.Rounding.Down);
    }
}

contract AssetToShareAmountTest is PricingLibBaseTest {
    using PricingLib for *;
    using MathLib for uint256;

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

        uint256 underestimate = pricePoolPerShare.reciprocalMulUint256(
            pricePoolPerAsset.mulUint256(
                uint256(assetAmount).mulDiv(10 ** SHARE_DECIMALS, 10 ** assetDecimals), MathLib.Rounding.Down
            ),
            MathLib.Rounding.Down
        );
        uint256 expectedDown = MathLib.mulDiv(
            assetAmount * 10 ** SHARE_DECIMALS,
            pricePoolPerAsset.inner(),
            10 ** assetDecimals * pricePoolPerShare.inner(),
            MathLib.Rounding.Down
        );
        uint256 expectedUp = MathLib.mulDiv(
            assetAmount * 10 ** SHARE_DECIMALS,
            pricePoolPerAsset.inner(),
            10 ** assetDecimals * pricePoolPerShare.inner(),
            MathLib.Rounding.Up
        );

        uint256 result = PricingLib.assetToShareAmount(
            assetAmount, assetDecimals, SHARE_DECIMALS, pricePoolPerAsset, pricePoolPerShare, MathLib.Rounding.Down
        );

        assertGe(result, underestimate, "assetToShareAmount should be at least as large as underestimate");
        assertEq(result, expectedDown, "assetToShareAmount failed");
        assertApproxEqAbs(expectedDown, expectedUp, 1, "Rounding diff should be at most one");
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
            assetAmount, assetDecimals, POOL_DECIMALS, pricePoolPerAsset, pricePoolPerShare, MathLib.Rounding.Down
        );
        uint256 assetRoundTrip = PricingLib.shareToAssetAmount(
            shareAmount, POOL_DECIMALS, assetDecimals, pricePoolPerAsset, pricePoolPerShare, MathLib.Rounding.Down
        );

        assertApproxEqAbs(assetRoundTrip, assetAmount, 1e7, "Asset->Share->Asset roundtrip target precision excess");
    }
}

contract ShareToAssetToShareTest is PricingLibBaseTest {
    using PricingLib for *;
    using MathLib for uint256;

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
            shareAmount, POOL_DECIMALS, assetDecimals, pricePoolPerAsset, pricePoolPerShare, MathLib.Rounding.Down
        );
        uint256 shareRoundTrip = PricingLib.assetToShareAmount(
            assetAmount, assetDecimals, POOL_DECIMALS, pricePoolPerAsset, pricePoolPerShare, MathLib.Rounding.Down
        );
        assertApproxEqAbs(shareRoundTrip, shareAmount, 1e19, "Share->Asset->Share roundtrip target precision excess");
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

        uint256 underestimate = pricePoolPerAsset.reciprocalMulUint256(
            pricePoolPerShare.mulUint256(
                uint256(shareAmount).mulDiv(10 ** assetDecimals, 10 ** SHARE_DECIMALS), MathLib.Rounding.Down
            ),
            MathLib.Rounding.Down
        );
        uint256 expectedDown = MathLib.mulDiv(
            shareAmount * 10 ** assetDecimals,
            pricePoolPerShare.inner(),
            10 ** SHARE_DECIMALS * pricePoolPerAsset.inner(),
            MathLib.Rounding.Down
        );
        uint256 expectedUp = MathLib.mulDiv(
            shareAmount * 10 ** assetDecimals,
            pricePoolPerShare.inner(),
            10 ** SHARE_DECIMALS * pricePoolPerAsset.inner(),
            MathLib.Rounding.Up
        );

        uint256 result = PricingLib.shareToAssetAmount(
            shareAmount, POOL_DECIMALS, assetDecimals, pricePoolPerAsset, pricePoolPerShare, MathLib.Rounding.Down
        );

        assertGe(result, underestimate, "shareToAssetAmount should be at least as large as underestimate");
        assertEq(result, expectedDown, "shareToAssetAmount failed");
        assertApproxEqAbs(expectedDown, expectedUp, 1, "Rounding diff should be at most one");
    }

    function testShareToAssetAmountZeroValues() public {
        address asset = makeAddr("Asset");
        address shareToken = makeAddr("ShareToken");

        // Test zero share amount
        uint256 result =
            PricingLib.shareToAssetAmount(shareToken, 0, asset, 0, d18(1e18), d18(1e18), MathLib.Rounding.Down);
        assertEq(result, 0, "Zero share amount should return 0");

        // Test zero pricePoolPerShare
        result = PricingLib.shareToAssetAmount(shareToken, 1e18, asset, 0, d18(1e18), d18(0), MathLib.Rounding.Down);
        assertEq(result, 0, "Zero pricePoolPerShare should return 0");

        // Test zero pricePoolPerAsset
        result = PricingLib.shareToAssetAmount(shareToken, 1e18, asset, 0, d18(0), d18(1e18), MathLib.Rounding.Down);
        assertEq(result, 0, "Zero pricePoolPerAsset should return 0");

        // Test all zeros
        result = PricingLib.shareToAssetAmount(shareToken, 0, asset, 0, d18(0), d18(0), MathLib.Rounding.Down);
        assertEq(result, 0, "All zeros should return 0");
    }
}

contract PoolToAssetAmountTest is PricingLibBaseTest {
    using PricingLib for *;
    using MathLib for uint256;

    function testPoolToAssetAmount(uint128 poolAmount, uint8 assetDecimals, uint64 pricePoolPerAsset_) public pure {
        assetDecimals = uint8(bound(assetDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        poolAmount = uint128(bound(poolAmount, 10 ** POOL_DECIMALS, MAX_AMOUNT));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));

        uint256 underestimate = pricePoolPerAsset.reciprocalMulUint256(
            uint256(poolAmount).mulDiv(10 ** assetDecimals, 10 ** POOL_DECIMALS, MathLib.Rounding.Down),
            MathLib.Rounding.Down
        );
        uint256 expectedDown = uint256(poolAmount).mulDiv(
            10 ** (assetDecimals + 18), 10 ** POOL_DECIMALS * pricePoolPerAsset.inner(), MathLib.Rounding.Down
        );
        uint256 expectedUp = uint256(poolAmount).mulDiv(
            10 ** (assetDecimals + 18), 10 ** POOL_DECIMALS * pricePoolPerAsset.inner(), MathLib.Rounding.Up
        );

        uint256 result = PricingLib.poolToAssetAmount(
            poolAmount, POOL_DECIMALS, assetDecimals, pricePoolPerAsset, MathLib.Rounding.Down
        );

        assertGe(result, underestimate, "shareToAssetAmount should be at least as large as underestimate");
        assertEq(result, expectedDown, "poolToAssetAmount failed");
        assertApproxEqAbs(expectedDown, expectedUp, 1, "Rounding diff should be at most one");
    }
}

contract CalcPriceAssetPerShareTest is Test {
    using PricingLib for *;
    using MathLib for uint256;

    address asset = makeAddr("Asset");
    address shareToken = makeAddr("ShareToken");

    uint8 ASSET_DECIMALS = 6;
    uint8 SHARE_DECIMALS = 16;

    function setUp() public {
        vm.mockCall(asset, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(ASSET_DECIMALS));
        vm.mockCall(shareToken, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(SHARE_DECIMALS));
    }

    function _assertPrice(uint256 shares, uint256 assets, uint256 expected, MathLib.Rounding rounding) internal view {
        uint256 calculated = PricingLib.calculatePriceAssetPerShare(
            shareToken, shares.toUint128(), asset, 0, assets.toUint128(), rounding
        );
        assertEq(calculated, expected);
    }

    function testIdentityPrice() public view {
        uint256 shares = 10 ** SHARE_DECIMALS;
        uint256 assets = 10 ** ASSET_DECIMALS;
        uint256 expected = 1e18;

        _assertPrice(shares, assets, expected, MathLib.Rounding.Down);
    }

    function testManual() public view {
        uint256 shares = 2e18;
        uint256 assets = 51;
        uint256 expected = 25.5e10; // 1e18 * 51 * 1e12 / 2e18 * 1e2

        _assertPrice(shares, assets, expected, MathLib.Rounding.Down);
    }

    function testEdgeCases() public view {
        // Zero values
        _assertPrice(0, 0, 0, MathLib.Rounding.Down);
        _assertPrice(0, type(uint128).max, 0, MathLib.Rounding.Down);
        _assertPrice(type(uint128).max, 0, 0, MathLib.Rounding.Down);

        // Minimum non-zero values
        _assertPrice(1, 1, 1e28, MathLib.Rounding.Down);

        // Maximum values
        _assertPrice(type(uint128).max, type(uint128).max, 1e28, MathLib.Rounding.Down);

        // Small assets, large shares
        _assertPrice(1e18, 1, 1e10, MathLib.Rounding.Down);

        // Large assets, small shares
        _assertPrice(1, 1e18, 1e46, MathLib.Rounding.Down);
    }

    function testRoundingModes() public view {
        uint256 shares = 3;
        uint256 assets = 10;
        uint256 expected = 10 ** 29;

        // Rounding.Down
        _assertPrice(shares, assets, expected / 3, MathLib.Rounding.Down);

        // Rounding.Up
        _assertPrice(shares, assets, expected / 3 + 1, MathLib.Rounding.Up);
    }
}
