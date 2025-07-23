// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../misc/types/D18.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {IERC20Metadata} from "../../misc/interfaces/IERC20.sol";
import {IERC6909MetadataExt} from "../../misc/interfaces/IERC6909.sol";

library PricingLib {
    using MathLib for *;

    /// @dev Prices are fixed-point integers with 18 decimals
    uint8 internal constant PRICE_DECIMALS = 18;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @dev Converts the given asset amount to share amount. Returned value is in share decimals.
    /// @dev Assumes handling of zero denominator price (priceAssetPerShare_) by consumer.
    ///
    ///      NOTE: MUST ONLY be used in AsyncRequestManager which rely on priceAssetPerShare that is derived from
    ///      Fulfilled* message amounts. Any other codepath must use the variant with pricePoolPerAsset
    ///      and pricePoolPerShare
    function assetToShareAmount(
        address shareToken,
        address asset,
        uint256 tokenId,
        uint128 assetAmount,
        D18 priceAssetPerShare_,
        MathLib.Rounding rounding
    ) internal view returns (uint128 shares) {
        if (assetAmount == 0) {
            return 0;
        }

        uint8 assetDecimals = _getAssetDecimals(asset, tokenId);
        uint8 shareDecimals = IERC20Metadata(shareToken).decimals();

        return PricingLib.convertWithReciprocalPrice(
            assetAmount, assetDecimals, shareDecimals, priceAssetPerShare_, rounding
        ).toUint128();
    }

    /// @dev Converts the given asset amount to share amount. Returned value is in share decimals.
    /// @dev Assumes handling of zero denominator price (pricePoolPerShare) by consumer.
    function assetToShareAmount(
        address shareToken,
        address asset,
        uint256 tokenId,
        uint128 assetAmount,
        D18 pricePoolPerAsset,
        D18 pricePoolPerShare,
        MathLib.Rounding rounding
    ) internal view returns (uint128 shares) {
        if (assetAmount == 0 || pricePoolPerAsset.isZero()) {
            return 0;
        }

        uint8 assetDecimals = _getAssetDecimals(asset, tokenId);
        uint8 shareDecimals = IERC20Metadata(shareToken).decimals();

        return PricingLib.assetToShareAmount(
            assetAmount, assetDecimals, shareDecimals, pricePoolPerAsset, pricePoolPerShare, rounding
        ).toUint128();
    }

    /// @dev Converts the given share amount to asset amount. Returned value is in share decimals.
    ///
    ///      NOTE: MUST ONLY be used in AsyncRequestManager which rely on priceAssetPerShare that is derived from
    ///      Fulfilled*  message amounts. Any other codepath must use the variant with pricePoolPerAsset and
    ///      pricePoolPerShare
    function shareToAssetAmount(
        address shareToken,
        uint128 shareAmount,
        address asset,
        uint256 tokenId,
        D18 priceAssetPerShare_,
        MathLib.Rounding rounding
    ) internal view returns (uint128 assets) {
        if (shareAmount == 0 || priceAssetPerShare_.isZero()) {
            return 0;
        }

        uint8 assetDecimals = _getAssetDecimals(asset, tokenId);
        uint8 shareDecimals = IERC20Metadata(shareToken).decimals();

        return PricingLib.convertWithPrice(shareAmount, shareDecimals, assetDecimals, priceAssetPerShare_, rounding);
    }

    /// @dev Converts the given share amount to asset amount. Returned value is in share decimals.
    /// @dev Assumes handling of zero denominator price (pricePoolPerAsset) by consumer.
    function shareToAssetAmount(
        address shareToken,
        uint128 shareAmount,
        address asset,
        uint256 tokenId,
        D18 pricePoolPerShare,
        D18 pricePoolPerAsset,
        MathLib.Rounding rounding
    ) internal view returns (uint128 shares) {
        if (shareAmount == 0 || pricePoolPerShare.isZero()) {
            return 0;
        }

        uint8 assetDecimals = _getAssetDecimals(asset, tokenId);
        uint8 shareDecimals = IERC20Metadata(shareToken).decimals();

        // NOTE: Pool and share denomination are always equal by design
        return PricingLib.shareToAssetAmount(
            shareAmount, shareDecimals, assetDecimals, pricePoolPerShare, pricePoolPerAsset, rounding
        ).toUint128();
    }

    /// @dev Calculates the asset price per share returns the value in price decimals
    ///      Denominated in ASSET_UNIT/SHARE_UNIT
    /// @dev Assumes handling of zero denominator (shares == 0) by consumer.
    function calculatePriceAssetPerShare(
        address shareToken,
        uint128 shares,
        address asset,
        uint256 tokenId,
        uint128 assets,
        MathLib.Rounding rounding
    ) internal view returns (D18 priceAssetPerShare_) {
        if (assets == 0) {
            return d18(0);
        }

        uint8 assetDecimals = _getAssetDecimals(asset, tokenId);
        uint8 shareDecimals = IERC20Metadata(shareToken).decimals();

        // NOTE: More precise than utilizing D18
        return d18(
            _toPriceDecimals(assets, assetDecimals).mulDiv(
                10 ** PRICE_DECIMALS, _toPriceDecimals(shares, shareDecimals), rounding
            ).toUint128()
        );
    }

    //----------------------------------------------------------------------------------------------
    // Pure methods
    //----------------------------------------------------------------------------------------------

    /// @dev Converts an amount using decimals and price with implicit rounding down
    function convertWithPrice(uint256 baseAmount, uint8 baseDecimals, uint8 quoteDecimals, D18 priceQuotePerBase)
        internal
        pure
        returns (uint128 quoteAmount)
    {
        return convertWithPrice(baseAmount, baseDecimals, quoteDecimals, priceQuotePerBase, MathLib.Rounding.Down);
    }

    /// @dev Converts an amount using decimals and price with explicit rounding.
    function convertWithPrice(
        uint256 baseAmount,
        uint8 baseDecimals,
        uint8 quoteDecimals,
        D18 priceQuotePerBase,
        MathLib.Rounding rounding
    ) internal pure returns (uint128 quoteAmount) {
        if (baseDecimals == quoteDecimals) {
            return priceQuotePerBase.mulUint256(baseAmount, rounding).toUint128();
        }

        return MathLib.mulDiv(
            priceQuotePerBase.raw(), baseAmount * 10 ** quoteDecimals, 10 ** (baseDecimals + PRICE_DECIMALS), rounding
        ) // cancel out exponentiation from D18 multiplication
            .toUint128();
    }

    /// @dev Converts an amount using decimals and reciprocal price.
    /// @dev Assumes handling of zero denominator price (priceBasePerQuote) by consumer.
    ///
    ///      NOTE: More precise than convertWithPrice(,,,price.reciprocal,)
    function convertWithReciprocalPrice(
        uint256 baseAmount,
        uint8 baseDecimals,
        uint8 quoteDecimals,
        D18 priceBasePerQuote,
        MathLib.Rounding rounding
    ) internal pure returns (uint128 quoteAmount) {
        require(priceBasePerQuote.isNotZero(), "PricingLib/division-by-zero");

        if (baseDecimals == quoteDecimals) {
            return priceBasePerQuote.reciprocalMulUint256(baseAmount, rounding).toUint128();
        }

        return MathLib.mulDiv(
            10 ** quoteDecimals * baseAmount,
            10 ** PRICE_DECIMALS,
            10 ** baseDecimals * priceBasePerQuote.raw(),
            rounding
        ).toUint128();
    }

    /// @dev Converts an amount using decimals and two prices.
    /// @dev Assumes handling of zero denominator price (priceDenominator) by consumer.
    ///
    ///      NOTE: More precise than custom math with one price and convertWith{Reciprocal}Price for the other
    function convertWithPrices(
        uint256 baseAmount,
        uint8 baseDecimals,
        uint8 quoteDecimals,
        D18 priceNumerator,
        D18 priceDenominator,
        MathLib.Rounding rounding
    ) internal pure returns (uint128 quoteAmount) {
        require(priceDenominator.isNotZero(), "PricingLib/division-by-zero");

        return MathLib.mulDiv(
            priceNumerator.raw(),
            10 ** quoteDecimals * baseAmount,
            10 ** baseDecimals * priceDenominator.raw(),
            rounding
        ).toUint128();
    }

    /// @dev Converts asset amount to share amount.
    /// @dev Assumes handling of zero denominator price (pricePoolPerShare) by consumer.
    ///
    ///      NOTE: Pool and share denomination are always equal by design
    function assetToShareAmount(
        uint256 assetAmount,
        uint8 assetDecimals,
        uint8 shareDecimals,
        D18 pricePoolPerAsset,
        D18 pricePoolPerShare,
        MathLib.Rounding rounding
    ) internal pure returns (uint128 shareAmount) {
        return
            convertWithPrices(assetAmount, assetDecimals, shareDecimals, pricePoolPerAsset, pricePoolPerShare, rounding);
    }

    /// @dev Converts share amount to asset asset amount.
    /// @dev Assumes handling of zero denominator price (pricePoolPerAsset) by consumer.
    ///
    ///      NOTE: Pool and share denomination are always equal by design
    function shareToAssetAmount(
        uint256 shareAmount,
        uint8 shareDecimals,
        uint8 assetDecimals,
        D18 pricePoolPerShare,
        D18 pricePoolPerAsset,
        MathLib.Rounding rounding
    ) internal pure returns (uint128 assetAmount) {
        return
            convertWithPrices(shareAmount, shareDecimals, assetDecimals, pricePoolPerShare, pricePoolPerAsset, rounding);
    }

    /// @dev Converts pool amount to asset amount.
    /// @dev Assumes handling of zero denominator price (pricePoolPerAsset) by consumer.
    function poolToAssetAmount(
        uint256 poolAmount,
        uint8 poolDecimals,
        uint8 assetDecimals,
        D18 pricePoolPerAsset,
        MathLib.Rounding rounding
    ) internal pure returns (uint128 assetAmount) {
        return convertWithReciprocalPrice(poolAmount, poolDecimals, assetDecimals, pricePoolPerAsset, rounding);
    }

    /// @dev Converts asset amount to pool amount.
    function assetToPoolAmount(
        uint128 assetAmount,
        uint8 assetDecimals,
        uint8 poolDecimals,
        D18 pricePoolPerAsset,
        MathLib.Rounding rounding
    ) internal pure returns (uint128 poolAmount) {
        return convertWithPrice(assetAmount, assetDecimals, poolDecimals, pricePoolPerAsset, rounding);
    }

    /// @dev Returns the asset price per share denominated in ASSET_UNIT/SHARE_UNIT
    /// @dev Assumes handling of zero denominator price (pricePoolPerAsset) by consumer.
    ///
    ///      NOTE: Should never be used for calculating amounts due to precision loss. Instead, please refer to
    ///      conversion relying on pricePoolPerShare and pricePoolPerAsset.
    function priceAssetPerShare(D18 pricePoolPerShare, D18 pricePoolPerAsset)
        internal
        pure
        returns (D18 priceAssetPerShare_)
    {
        return pricePoolPerShare / pricePoolPerAsset;
    }

    //----------------------------------------------------------------------------------------------
    // Private methods
    //----------------------------------------------------------------------------------------------

    /// @dev Returns the asset decimals
    function _getAssetDecimals(address asset, uint256 tokenId) private view returns (uint8 assetDecimals) {
        return tokenId == 0 ? IERC20Metadata(asset).decimals() : IERC6909MetadataExt(asset).decimals(tokenId);
    }

    /// @dev When converting assets to shares using the price, all values are normalized to PRICE_DECIMALS
    ///      NOTE: We require all assets to have 2 <= decimals <= 18, see `Spoke.registerAsset`
    function _toPriceDecimals(uint128 _value, uint8 decimals) private pure returns (uint256) {
        if (PRICE_DECIMALS == decimals) return uint256(_value);
        return uint256(_value) * 10 ** (PRICE_DECIMALS - decimals);
    }
}
