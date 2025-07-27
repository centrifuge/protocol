// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {D18, d18} from "../../../../src/misc/types/D18.sol";
import {MathLib} from "../../../../src/misc/libraries/MathLib.sol";
import {IERC20Metadata} from "../../../../src/misc/interfaces/IERC20.sol";

import {PricingLib} from "../../../../src/common/libraries/PricingLib.sol";

import "forge-std/Test.sol";

contract PricingLibBaseTest is Test {
    using PricingLib for *;
    using MathLib for uint256;

    uint8 constant MIN_ASSET_DECIMALS = 2;
    uint8 constant MAX_ASSET_DECIMALS = 18;
    uint8 constant POOL_DECIMALS = 18;
    uint8 constant SHARE_DECIMALS = POOL_DECIMALS;
    uint128 constant MIN_PRICE = 1; // NOTE: 0 prices are handled separately
    uint128 constant MAX_PRICE_POOL_PER_ASSET = 1e30;
    uint128 constant MAX_PRICE_POOL_PER_SHARE = 1e30;
    uint128 constant MAX_AMOUNT = 1e24;
}

contract ConvertWithPriceTest is PricingLibBaseTest {
    using PricingLib for *;
    using MathLib for uint256;

    function testConvertWithPriceSimple() public pure {
        uint8 baseDecimals = 2;
        uint8 quoteDecimals = 18;
        uint128 baseAmount = 4e10;
        D18 priceQuotePerBase = d18(2e10);

        uint256 expected = priceQuotePerBase.raw() * baseAmount * 10 ** (quoteDecimals - baseDecimals) / 1e18;

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

    function testConvertWithPrice(uint128 baseAmount, uint8 baseDecimals, uint8 quoteDecimals, uint128 priceRaw)
        public
        pure
    {
        baseDecimals = uint8(bound(baseDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        quoteDecimals = uint8(bound(quoteDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        baseAmount = uint128(bound(baseAmount, 1, MAX_AMOUNT / (10 ** quoteDecimals)));
        D18 price = d18(uint128(bound(priceRaw, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));

        uint256 scaledBase;
        if (baseDecimals > quoteDecimals) {
            scaledBase = baseAmount / (10 ** (baseDecimals - quoteDecimals));
        } else {
            scaledBase = baseAmount * (10 ** (quoteDecimals - baseDecimals));
        }

        uint256 underestimate = price.mulUint256(scaledBase, MathLib.Rounding.Down);
        uint256 expectedDown = MathLib.mulDiv(
            baseAmount * 10 ** quoteDecimals, price.raw(), 10 ** baseDecimals * 1e18, MathLib.Rounding.Down
        );
        uint256 expectedUp = MathLib.mulDiv(
            baseAmount * 10 ** quoteDecimals, price.raw(), 10 ** baseDecimals * 1e18, MathLib.Rounding.Up
        );
        uint256 result = PricingLib.convertWithPrice(baseAmount, baseDecimals, quoteDecimals, price);

        assertGe(result, underestimate, "convertWithPrice should be at least as large as underestimate");
        assertEq(result, expectedDown, "convertWithPrice failed");
        assertApproxEqAbs(expectedDown, expectedUp, 1, "Rounding diff should be at most one");
    }

    function testConvertWithPriceZeroValues() public pure {
        uint256 result = PricingLib.convertWithPrice(0, 6, 18, d18(1e18), MathLib.Rounding.Down);
        assertEq(result, 0, "Zero asset amount should return 0");

        result = PricingLib.convertWithPrice(1e6, 6, 18, d18(0), MathLib.Rounding.Down);
        assertEq(result, 0, "Zero pricePoolPerAsset should return 0");

        result = PricingLib.convertWithPrice(0, 6, 18, d18(0), MathLib.Rounding.Down);
        assertEq(result, 0, "All zeros should return 0");
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
        uint128 maxBaseAmount = type(uint64).max;
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

        uint256 expected = baseAmount * 10 ** quoteDecimals * 1e18 / (10 ** baseDecimals * priceBasePerQuote.raw());

        assertEq(expected, 4e34);
        assertEq(
            PricingLib.convertWithReciprocalPrice(
                baseAmount, baseDecimals, quoteDecimals, priceBasePerQuote, MathLib.Rounding.Down
            ),
            expected
        );
    }

    function testConvertWithReciprocalPriceSameDecimals(uint128 baseAmount, uint128 priceRaw) public pure {
        baseAmount = uint128(bound(baseAmount, 0, type(uint128).max / (10 ** 18)));
        D18 price = d18(uint128(bound(priceRaw, MIN_PRICE, type(uint128).max / (10 ** 18))));

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
        baseDecimals = uint8(bound(baseDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        quoteDecimals = uint8(bound(quoteDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        baseAmount = uint128(bound(baseAmount, 0, type(uint128).max / (10 ** quoteDecimals)));
        D18 price = d18(uint128(bound(priceRaw, MIN_PRICE, type(uint128).max / (10 ** baseDecimals))));

        vm.assume(10 ** (18 + quoteDecimals) * baseAmount < type(uint128).max * 10 ** baseDecimals * price.raw());

        uint256 scaledBase;
        if (baseDecimals > quoteDecimals) {
            scaledBase = baseAmount / (10 ** (baseDecimals - quoteDecimals));
        } else {
            scaledBase = baseAmount * (10 ** (quoteDecimals - baseDecimals));
        }
        uint256 underestimate = price.reciprocalMulUint256(scaledBase, MathLib.Rounding.Down);
        uint256 expectedDown = MathLib.mulDiv(
            baseAmount * 10 ** quoteDecimals, 1e18, 10 ** baseDecimals * price.raw(), MathLib.Rounding.Down
        );
        uint256 expectedUp = MathLib.mulDiv(
            baseAmount * 10 ** quoteDecimals, 1e18, 10 ** baseDecimals * price.raw(), MathLib.Rounding.Up
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
        uint256 maxBaseAmount = type(uint64).max;
        D18 price = d18(type(uint128).max);
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
            priceNumerator.raw() * baseAmount * 10 ** quoteDecimals / (10 ** baseDecimals * priceDenominator.raw());

        assertEq(expected, 1e26);
        assertEq(
            PricingLib.convertWithPrices(
                baseAmount, baseDecimals, quoteDecimals, priceNumerator, priceDenominator, MathLib.Rounding.Down
            ),
            expected
        );
    }

    function testConvertWithPricesSameDecimals(uint128 baseAmount, uint128 priceNumerator_, uint128 priceDenominator_)
        public
        pure
    {
        baseAmount = uint128(bound(baseAmount, 0, MAX_AMOUNT));
        D18 priceDenominator = d18(uint128(bound(priceDenominator_, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));
        D18 priceNumerator = d18(
            uint128(
                bound(
                    priceNumerator_, MIN_PRICE, uint256(type(uint128).max) / (baseAmount + 1) * priceDenominator.raw()
                )
            )
        );

        uint256 expected =
            MathLib.mulDiv(priceNumerator.raw(), baseAmount, priceDenominator.raw(), MathLib.Rounding.Down);
        uint256 result =
            PricingLib.convertWithPrices(baseAmount, 18, 18, priceNumerator, priceDenominator, MathLib.Rounding.Down);
        assertEq(result, expected);
    }

    function testConvertWithPricesDifferentDecimals(
        uint128 baseAmount,
        uint8 baseDecimals,
        uint8 quoteDecimals,
        uint128 priceNumerator_,
        uint128 priceDenominator_
    ) public pure {
        baseDecimals = uint8(bound(baseDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        quoteDecimals = uint8(bound(quoteDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        baseAmount = uint128(bound(baseAmount, 1, type(uint128).max / (10 ** quoteDecimals)));
        D18 priceDenominator = d18(uint128(bound(priceDenominator_, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));
        D18 priceNumerator = d18(
            uint128(
                bound(
                    priceNumerator_,
                    0,
                    10 ** baseDecimals * 1e28 / (10 ** quoteDecimals * (baseAmount + 1)) * priceDenominator.raw()
                )
            )
        );
        uint256 scaledBase;
        if (baseDecimals > quoteDecimals) {
            scaledBase = baseAmount / (10 ** (baseDecimals - quoteDecimals));
        } else {
            scaledBase = baseAmount * (10 ** (quoteDecimals - baseDecimals));
        }
        uint256 underestimate =
            MathLib.mulDiv(priceNumerator.raw(), scaledBase, priceDenominator.raw(), MathLib.Rounding.Down);
        uint256 expectedUp = MathLib.mulDiv(
            priceNumerator.raw(),
            10 ** quoteDecimals * baseAmount,
            10 ** baseDecimals * priceDenominator.raw(),
            MathLib.Rounding.Up
        );
        uint256 expectedDown = MathLib.mulDiv(
            priceNumerator.raw(),
            uint256(baseAmount) * 10 ** quoteDecimals,
            10 ** baseDecimals * uint256(priceDenominator.raw()),
            MathLib.Rounding.Down
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
        uint256 maxBaseAmount = type(uint64).max;

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

    function _setUpBounds(
        uint128 assetAmount_,
        uint8 assetDecimals_,
        uint128 pricePoolPerAsset_,
        uint128 pricePoolPerShare_
    )
        internal
        pure
        returns (
            uint128 assetAmount,
            uint8 assetDecimals,
            D18 pricePoolPerAsset,
            D18 pricePoolPerShare,
            uint256 poolAmount
        )
    {
        assetDecimals = uint8(bound(assetDecimals_, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        assetAmount = uint128(bound(assetAmount_, 0, type(uint128).max / (10 ** assetDecimals)));
        pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));
        pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, MIN_PRICE, MAX_PRICE_POOL_PER_SHARE)));

        poolAmount = pricePoolPerAsset.mulUint256(
            uint256(assetAmount).mulDiv(10 ** SHARE_DECIMALS, 10 ** assetDecimals), MathLib.Rounding.Down
        );
        vm.assume(poolAmount < type(uint128).max / 1e18);
    }

    function testAssetToShareAmount(
        uint128 assetAmount_,
        uint8 assetDecimals_,
        uint128 pricePoolPerAsset_,
        uint128 pricePoolPerShare_
    ) public pure {
        (uint128 assetAmount, uint8 assetDecimals, D18 pricePoolPerAsset, D18 pricePoolPerShare, uint256 poolAmount) =
            _setUpBounds(assetAmount_, assetDecimals_, pricePoolPerAsset_, pricePoolPerShare_);

        uint256 underestimate = pricePoolPerShare.reciprocalMulUint256(poolAmount, MathLib.Rounding.Down);
        uint256 expectedDown = MathLib.mulDiv(
            assetAmount * 10 ** SHARE_DECIMALS,
            pricePoolPerAsset.raw(),
            10 ** assetDecimals * pricePoolPerShare.raw(),
            MathLib.Rounding.Down
        );
        uint256 expectedUp = MathLib.mulDiv(
            assetAmount * 10 ** SHARE_DECIMALS,
            pricePoolPerAsset.raw(),
            10 ** assetDecimals * pricePoolPerShare.raw(),
            MathLib.Rounding.Up
        );

        uint256 result = PricingLib.assetToShareAmount(
            assetAmount, assetDecimals, POOL_DECIMALS, pricePoolPerAsset, pricePoolPerShare, MathLib.Rounding.Down
        );

        assertGe(result, underestimate, "assetToShareAmount should be at least as large as underestimate");
        assertEq(result, expectedDown, "assetToShareAmount failed");
        assertApproxEqAbs(expectedDown, expectedUp, 1, "Rounding diff should be at most one");
    }

    /// NOTE: Precision is horrible with fuzzed inputs but still reflects a worst case which is better than nothing
    function testAssetToShareToAssetRoundTrip(
        uint128 assetAmount_,
        uint8 assetDecimals_,
        uint64 pricePoolPerAsset_,
        uint64 pricePoolPerShare_
    ) public pure {
        (uint128 assetAmount, uint8 assetDecimals, D18 pricePoolPerAsset, D18 pricePoolPerShare,) =
            _setUpBounds(assetAmount_, assetDecimals_, pricePoolPerAsset_, pricePoolPerShare_);

        uint256 shareAmount = PricingLib.assetToShareAmount(
            assetAmount, assetDecimals, POOL_DECIMALS, pricePoolPerAsset, pricePoolPerShare, MathLib.Rounding.Down
        );
        uint256 assetRoundTrip = PricingLib.shareToAssetAmount(
            shareAmount, POOL_DECIMALS, assetDecimals, pricePoolPerShare, pricePoolPerAsset, MathLib.Rounding.Down
        );

        assertApproxEqAbs(assetRoundTrip, assetAmount, 1e20, "Asset->Share->Asset roundtrip target precision excess");
    }
}

contract ShareToAssetToShareTest is PricingLibBaseTest {
    using PricingLib for *;
    using MathLib for uint256;

    /// NOTE: Precision is horrible with fuzzed inputs but still reflects a worst case which is better than nothing
    function testShareToAssetToShareRoundTrip(
        uint128 shareAmount,
        uint8 assetDecimals,
        uint64 pricePoolPerAsset_,
        uint64 pricePoolPerShare_
    ) public pure {
        assetDecimals = uint8(bound(assetDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        shareAmount = uint128(bound(shareAmount, 0, (type(uint128).max / 10 ** assetDecimals)));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));
        D18 pricePoolPerShare = d18(
            uint128(
                bound(
                    pricePoolPerShare_,
                    MIN_PRICE,
                    (10 ** 18 * pricePoolPerAsset.raw() * uint256(type(uint128).max))
                        / (10 ** assetDecimals * (shareAmount + 1))
                )
            )
        );

        uint256 assetAmount = PricingLib.shareToAssetAmount(
            shareAmount, POOL_DECIMALS, assetDecimals, pricePoolPerShare, pricePoolPerAsset, MathLib.Rounding.Down
        );
        uint256 shareRoundTrip = PricingLib.assetToShareAmount(
            assetAmount, assetDecimals, POOL_DECIMALS, pricePoolPerAsset, pricePoolPerShare, MathLib.Rounding.Down
        );
        assertApproxEqAbs(shareRoundTrip, shareAmount, 1e36, "Share->Asset->Share roundtrip target precision excess");
    }

    function testShareToAssetAmount(
        uint128 shareAmount,
        uint8 assetDecimals,
        uint64 pricePoolPerShare_,
        uint64 pricePoolPerAsset_
    ) public pure {
        assetDecimals = uint8(bound(assetDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        shareAmount = uint128(bound(shareAmount, 0, (type(uint128).max / 10 ** assetDecimals)));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));
        D18 pricePoolPerShare = d18(
            uint128(
                bound(
                    pricePoolPerShare_,
                    MIN_PRICE,
                    (10 ** 18 * pricePoolPerAsset.raw() * uint256(type(uint128).max))
                        / (10 ** assetDecimals * (shareAmount + 1))
                )
            )
        );
        uint256 underestimate = pricePoolPerAsset.reciprocalMulUint256(
            pricePoolPerShare.mulUint256(
                uint256(shareAmount).mulDiv(10 ** assetDecimals, 10 ** SHARE_DECIMALS), MathLib.Rounding.Down
            ),
            MathLib.Rounding.Down
        );
        uint256 expectedDown = MathLib.mulDiv(
            shareAmount * 10 ** assetDecimals,
            pricePoolPerShare.raw(),
            10 ** SHARE_DECIMALS * pricePoolPerAsset.raw(),
            MathLib.Rounding.Down
        );
        uint256 expectedUp = MathLib.mulDiv(
            shareAmount * 10 ** assetDecimals,
            pricePoolPerShare.raw(),
            10 ** SHARE_DECIMALS * pricePoolPerAsset.raw(),
            MathLib.Rounding.Up
        );

        uint256 result = PricingLib.shareToAssetAmount(
            shareAmount, POOL_DECIMALS, assetDecimals, pricePoolPerShare, pricePoolPerAsset, MathLib.Rounding.Down
        );

        assertGe(result, underestimate, "shareToAssetAmount should be at least as large as underestimate");
        assertEq(result, expectedDown, "shareToAssetAmount failed");
        assertApproxEqAbs(expectedDown, expectedUp, 1, "Rounding diff should be at most one");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testShareToAssetAmountZeroValues() public {
        address asset = makeAddr("Asset");
        address shareToken = makeAddr("ShareToken");

        // Test zero share amount
        uint256 result =
            PricingLib.shareToAssetAmount(shareToken, 0, asset, 0, d18(1e18), d18(1e18), MathLib.Rounding.Down);
        assertEq(result, 0, "Zero share amount should return 0");

        // Test zero pricePoolPerShare - should return 0 gracefully
        result = PricingLib.shareToAssetAmount(shareToken, 1e18, asset, 0, d18(0), d18(1e18), MathLib.Rounding.Down);
        assertEq(result, 0, "Zero pricePoolPerShare should return 0");

        // Test zero pricePoolPerAsset - consumers should handle this case before calling but let's test it anyway
        vm.expectRevert(bytes("PricingLib/division-by-zero"));
        PricingLib.shareToAssetAmount(1e18, 18, 6, d18(1e18), d18(0), MathLib.Rounding.Down);

        // Test all zeros - should return 0 gracefully
        result = PricingLib.shareToAssetAmount(shareToken, 0, asset, 0, d18(0), d18(0), MathLib.Rounding.Down);
        assertEq(result, 0, "All zeros should return 0");
    }
}

contract PoolToAssetAmountTest is PricingLibBaseTest {
    using PricingLib for *;
    using MathLib for uint256;

    function testPoolToAssetAmount(uint128 poolAmount, uint8 assetDecimals, uint64 pricePoolPerAsset_) public pure {
        assetDecimals = uint8(bound(assetDecimals, MIN_ASSET_DECIMALS, MAX_ASSET_DECIMALS));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, MIN_PRICE, MAX_PRICE_POOL_PER_ASSET)));
        poolAmount =
            uint128(bound(poolAmount, 0, type(uint128).max / (10 ** (assetDecimals + 18) * pricePoolPerAsset.raw())));

        uint256 underestimate = pricePoolPerAsset.reciprocalMulUint256(
            uint256(poolAmount).mulDiv(10 ** assetDecimals, 10 ** POOL_DECIMALS, MathLib.Rounding.Down),
            MathLib.Rounding.Down
        );
        uint256 expectedDown = uint256(poolAmount).mulDiv(
            10 ** (assetDecimals + 18), 10 ** POOL_DECIMALS * pricePoolPerAsset.raw(), MathLib.Rounding.Down
        );
        uint256 expectedUp = uint256(poolAmount).mulDiv(
            10 ** (assetDecimals + 18), 10 ** POOL_DECIMALS * pricePoolPerAsset.raw(), MathLib.Rounding.Up
        );

        uint256 result = PricingLib.poolToAssetAmount(
            poolAmount, POOL_DECIMALS, assetDecimals, pricePoolPerAsset, MathLib.Rounding.Down
        );

        assertGe(result, underestimate, "shareToAssetAmount should be at least as large as underestimate");
        assertEq(result, expectedDown, "poolToAssetAmount failed");
        assertApproxEqAbs(expectedDown, expectedUp, 1, "Rounding diff should be at most one");
    }
}

contract AssetToPoolAmountTest is ConvertWithPriceTest {
    using PricingLib for *;
    using MathLib for uint256;

    function testAssetToPoolAmount(
        uint128 assetAmount,
        uint8 assetDecimals,
        uint8 poolDecimals,
        uint128 pricePoolPerAsset
    ) public pure {
        testConvertWithPrice(assetAmount, assetDecimals, poolDecimals, pricePoolPerAsset);
    }

    function testAssetToPoolAmountSameDecimals(uint128 baseAmount, uint128 pricePoolPerAsset) public pure {
        testConvertWithPriceSameDecimals(baseAmount, pricePoolPerAsset);
    }

    function testAssetToPoolAmountZeroValues() public pure {
        testConvertWithPriceZeroValues();
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

    function _assertPrice(uint256 shares, uint256 assets, uint128 expected, MathLib.Rounding rounding) internal view {
        D18 calculated = shares == 0
            ? d18(0)
            : PricingLib.calculatePriceAssetPerShare(shareToken, shares.toUint128(), asset, 0, assets.toUint128(), rounding);
        assertEq(calculated.raw(), expected);
    }

    function testIdentityPrice() public view {
        uint256 shares = 10 ** SHARE_DECIMALS;
        uint256 assets = 10 ** ASSET_DECIMALS;
        uint128 expected = 1e18;

        _assertPrice(shares, assets, expected, MathLib.Rounding.Down);
    }

    function testManual() public view {
        uint256 shares = 2e18;
        uint256 assets = 51;
        uint128 expected = 25.5e10; // 1e18 * 51 * 1e12 / 2e18 * 1e2

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
        _assertPrice(1, 1e10, 1e38, MathLib.Rounding.Down);
    }

    function testRoundingModes() public view {
        uint256 shares = 3;
        uint256 assets = 10;
        uint128 expected = 10 ** 29;

        // Rounding.Down
        _assertPrice(shares, assets, expected / 3, MathLib.Rounding.Down);

        // Rounding.Up
        _assertPrice(shares, assets, expected / 3 + 1, MathLib.Rounding.Up);
    }
}
