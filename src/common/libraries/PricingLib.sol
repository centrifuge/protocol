// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import {IERC6909MetadataExt} from "src/misc/interfaces/IERC6909.sol";
import {D18, d18} from "src/misc/types/D18.sol";

import {PricingLib} from "src/common/libraries/PricingLib.sol";

library PricingLib {
    using MathLib for *;

    /// @dev Prices are fixed-point integers with 18 decimals
    uint8 internal constant PRICE_DECIMALS = 18;

    /// -----------------------------------------------------
    ///  View Methods
    /// -----------------------------------------------------

    /// @dev Converts the given asset amount to share amount. Returned value is in share decimals.
    ///
    /// @dev NOTE: MUST ONLY be used in AsyncRequestManager which rely on priceAssetPerShare that is derived from
    /// Fulfilled*
    /// message amounts. Any other codepath must use the variant with pricePoolPerAsset and pricePoolPerShare
    function assetToShareAmount(
        address shareToken,
        address asset,
        uint256 tokenId,
        uint128 assetAmount,
        D18 priceAssetPerShare_,
        MathLib.Rounding rounding
    ) internal view returns (uint128 shares) {
        if (assetAmount == 0 || priceAssetPerShare_.raw() == 0) {
            return 0;
        }

        uint8 assetDecimals = getAssetDecimals(asset, tokenId);
        uint8 shareDecimals = IERC20Metadata(shareToken).decimals();

        return PricingLib.convertWithReciprocalPrice(
            assetAmount, assetDecimals, shareDecimals, priceAssetPerShare_, rounding
        ).toUint128();
    }

    /// @dev Converts the given asset amount to share amount. Returned value is in share decimals.
    function assetToShareAmount(
        address shareToken,
        address asset,
        uint256 tokenId,
        uint128 assetAmount,
        D18 pricePoolPerAsset,
        D18 pricePoolPerShare,
        MathLib.Rounding rounding
    ) internal view returns (uint128 shares) {
        if (assetAmount == 0 || pricePoolPerShare.raw() == 0 || pricePoolPerAsset.raw() == 0) {
            return 0;
        }

        uint8 assetDecimals = getAssetDecimals(asset, tokenId);
        uint8 shareDecimals = IERC20Metadata(shareToken).decimals();

        return PricingLib.assetToShareAmount(
            assetAmount, assetDecimals, shareDecimals, pricePoolPerAsset, pricePoolPerShare, rounding
        ).toUint128();
    }

    /// @dev Converts the given share amount to asset amount. Returned value is in share decimals.
    ///
    /// @dev NOTE: MUST ONLY be used in AsyncRequestManager which rely on priceAssetPerShare that is derived from
    /// Fulfilled*
    /// message amounts. Any other codepath must use the variant with pricePoolPerAsset and pricePoolPerShare
    function shareToAssetAmount(
        address shareToken,
        uint128 shareAmount,
        address asset,
        uint256 tokenId,
        D18 priceAssetPerShare_,
        MathLib.Rounding rounding
    ) internal view returns (uint128 shares) {
        if (shareAmount == 0 || priceAssetPerShare_.raw() == 0) {
            return 0;
        }

        uint8 assetDecimals = getAssetDecimals(asset, tokenId);
        uint8 shareDecimals = IERC20Metadata(shareToken).decimals();

        return PricingLib.convertWithPrice(shareAmount, shareDecimals, assetDecimals, priceAssetPerShare_, rounding)
            .toUint128();
    }

    /// @dev Converts the given share amount to asset amount. Returned value is in share decimals.
    function shareToAssetAmount(
        address shareToken,
        uint128 shareAmount,
        address asset,
        uint256 tokenId,
        D18 pricePoolPerAsset,
        D18 pricePoolPerShare,
        MathLib.Rounding rounding
    ) internal view returns (uint128 shares) {
        if (shareAmount == 0 || pricePoolPerShare.raw() == 0 || pricePoolPerAsset.raw() == 0) {
            return 0;
        }

        uint8 assetDecimals = getAssetDecimals(asset, tokenId);
        uint8 shareDecimals = IERC20Metadata(shareToken).decimals();

        return PricingLib.shareToAssetAmount(
            shareAmount, shareDecimals, assetDecimals, pricePoolPerAsset, pricePoolPerShare, rounding
        ).toUint128();
    }

    /// @dev Calculates the asset price per share returns the value in price decimals
    /// Denominated in ASSET_UNIT/SHARE_UNIT
    function calculatePriceAssetPerShare(
        address shareToken,
        uint128 shares,
        address asset,
        uint256 tokenId,
        uint128 assets,
        MathLib.Rounding rounding
    ) internal view returns (uint256 priceAssetPerShare_) {
        if (assets == 0 || shares == 0) {
            return 0;
        }

        uint8 assetDecimals = getAssetDecimals(asset, tokenId);
        uint8 shareDecimals = IERC20Metadata(shareToken).decimals();

        // NOTE: More precise than d18(assets * 10 ** assetDecimals, shares * 10 ** shareDecimals)
        return toPriceDecimals(assets, assetDecimals).mulDiv(
            10 ** PRICE_DECIMALS, toPriceDecimals(shares, shareDecimals), rounding
        );
    }

    /// -----------------------------------------------------
    ///  Pure Methods
    /// -----------------------------------------------------

    /// @dev Converts an amount using decimals and price with implicit rounding down
    function convertWithPrice(uint256 baseAmount, uint8 baseDecimals, uint8 quoteDecimals, D18 priceQuotePerBase)
        internal
        pure
        returns (uint256 quoteAmount)
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
    ) internal pure returns (uint256 quoteAmount) {
        if (baseDecimals == quoteDecimals) {
            return priceQuotePerBase.mulUint256(baseAmount, rounding);
        }

        return
            priceQuotePerBase.mulUint256(MathLib.mulDiv(baseAmount, 10 ** quoteDecimals, 10 ** baseDecimals), rounding);
    }

    /// @dev Converts an amount using decimals and reciprocal price.
    ///
    /// NOTE: More precise than convertWithPrice(,,,price.reciprocal,)
    function convertWithReciprocalPrice(
        uint256 baseAmount,
        uint8 baseDecimals,
        uint8 quoteDecimals,
        D18 priceBasePerQuote,
        MathLib.Rounding rounding
    ) internal pure returns (uint256 quoteAmount) {
        if (baseDecimals == quoteDecimals) {
            return priceBasePerQuote.reciprocalMulUint256(baseAmount, rounding);
        }

        return priceBasePerQuote.reciprocalMulUint256(
            MathLib.mulDiv(baseAmount, 10 ** quoteDecimals, 10 ** baseDecimals), rounding
        );
    }

    /// @dev Converts asset amount to share amount.
    function assetToShareAmount(
        uint256 assetAmount,
        uint8 assetDecimals,
        uint8 shareDecimals,
        D18 pricePoolPerAsset,
        D18 pricePoolPerShare,
        MathLib.Rounding rounding
    ) internal pure returns (uint256 shareAmount) {
        return pricePoolPerShare.reciprocalMulUint256(
            convertWithPrice(assetAmount, assetDecimals, shareDecimals, pricePoolPerAsset, MathLib.Rounding.Down),
            rounding
        );
    }

    /// @dev Converts share amount to asset asset amount.
    function shareToAssetAmount(
        uint256 shareAmount,
        uint8 shareDecimals,
        uint8 assetDecimals,
        D18 pricePoolPerAsset,
        D18 pricePoolPerShare,
        MathLib.Rounding rounding
    ) internal pure returns (uint256 assetAmount) {
        return convertWithReciprocalPrice(
            pricePoolPerShare.mulUint256(shareAmount, MathLib.Rounding.Down),
            shareDecimals,
            assetDecimals,
            pricePoolPerAsset,
            rounding
        );
    }

    /// @dev Converts pool amount to asset amount.
    function poolToAssetAmount(
        uint256 poolAmount,
        uint8 poolDecimals,
        uint8 assetDecimals,
        D18 pricePoolPerAsset,
        MathLib.Rounding rounding
    ) internal pure returns (uint256 assetAmount) {
        return convertWithReciprocalPrice(poolAmount, poolDecimals, assetDecimals, pricePoolPerAsset, rounding);
    }

    /// @dev Returns the asset price per share denominated in ASSET_UNIT/SHARE_UNIT
    ///
    /// @dev NOTE: Should never be used for calculating amounts due to precision loss. Instead, please refer to
    /// conversion relying on pricePoolPerShare and pricePoolPerAsset.
    function priceAssetPerShare(D18 pricePoolPerShare, D18 pricePoolPerAsset)
        internal
        pure
        returns (D18 priceAssetPerShare_)
    {
        return pricePoolPerShare / pricePoolPerAsset;
    }

    /// -----------------------------------------------------
    ///  Private Methods
    /// -----------------------------------------------------

    /// @dev Returns the asset decimals
    function getAssetDecimals(address asset, uint256 tokenId) private view returns (uint8 assetDecimals) {
        return tokenId == 0 ? IERC20Metadata(asset).decimals() : IERC6909MetadataExt(asset).decimals(tokenId);
    }

    /// @dev When converting assets to shares using the price, all values are normalized to PRICE_DECIMALS
    /// @dev NOTE: We require all assets to have 2 <= decimals <= 18, see `PoolManager.registerAsset`
    function toPriceDecimals(uint128 _value, uint8 decimals) private pure returns (uint256) {
        if (PRICE_DECIMALS == decimals) return uint256(_value);
        return uint256(_value) * 10 ** (PRICE_DECIMALS - decimals);
    }

    /// @dev Converts decimals of the value from the price decimals back to the intended decimals
    /// @dev NOTE: We require all assets to have 2 <= decimals <= 18, see `PoolManager.registerAsset`
    function fromPriceDecimals(uint256 _value, uint8 decimals) private pure returns (uint128) {
        if (PRICE_DECIMALS == decimals) return _value.toUint128();
        return (_value / 10 ** (PRICE_DECIMALS - decimals)).toUint128();
    }
}
