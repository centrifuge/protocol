// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MathLib} from "src/misc/libraries/MathLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";

library ConversionLib {
    using MathLib for uint256;

    /// @dev Converts an amount using decimals and price.
    function convertWithPrice(uint256 baseAmount, uint8 baseDecimals, uint8 quoteDecimals, D18 price)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        if (baseDecimals == quoteDecimals) {
            return price.mulUint256(baseAmount);
        }

        return price.mulUint256(MathLib.mulDiv(baseAmount, 10 ** quoteDecimals, 10 ** baseDecimals));
    }

    /// @dev Converts asset amount to share amount.
    function assetToShareAmount(
        uint256 assetAmount,
        uint8 assetDecimals,
        uint8 poolDecimals,
        D18 pricePoolPerAsset,
        D18 pricePoolPerShare
    ) internal pure returns (uint256 shareAmount) {
        uint256 poolAmount = convertWithPrice(assetAmount, assetDecimals, poolDecimals, pricePoolPerAsset);
        return pricePoolPerShare.reciprocalMulUint256(poolAmount);
    }

    /// @dev Converts share amount to asset asset amount.
    function shareToAssetAmount(
        uint256 shareAmount,
        uint8 poolDecimals,
        uint8 assetDecimals,
        D18 pricePoolPerShare,
        D18 pricePoolPerAsset
    ) internal pure returns (uint256 assetAmount) {
        uint256 poolAmount = pricePoolPerShare.mulUint256(shareAmount);
        return convertWithPrice(poolAmount, poolDecimals, assetDecimals, pricePoolPerAsset.reciprocal());
    }

    /// @dev Converts pool amount to asset amount.
    function poolToAssetAmount(uint256 poolAmount, uint8 poolDecimals, uint8 assetDecimals, D18 pricePoolPerAsset)
        internal
        pure
        returns (uint256 assetAmount)
    {
        return convertWithPrice(poolAmount, poolDecimals, assetDecimals, pricePoolPerAsset.reciprocal());
    }
}
