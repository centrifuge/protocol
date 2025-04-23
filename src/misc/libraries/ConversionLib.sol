// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MathLib} from "src/misc/libraries/MathLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";

library ConversionLib {
    using MathLib for uint256;

    // TODO: Add tests
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

    // TODO: Add tests
    function assetToShareAmount(
        uint256 assetAmount,
        uint8 assetDecimals,
        uint8 shareDecimals,
        D18 pricePoolPerAsset,
        D18 pricePoolPerShare
    ) internal pure returns (uint256 quoteAmount) {
        return pricePoolPerShare.reciprocalMulUint256(
            convertWithPrice(assetAmount, assetDecimals, shareDecimals, pricePoolPerAsset)
        );
    }

    // TODO: Test
    function poolToAssetAmount(uint256 poolAmount, uint8 poolDecimals, uint8 assetDecimals, D18 pricePoolPerAsset)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        return convertWithPrice(poolAmount, poolDecimals, assetDecimals, pricePoolPerAsset.reciprocal());
    }

    // TODO: Test
    function shareToAssetAmount(
        uint256 shareAmount,
        uint8 poolDecimals,
        uint8 assetDecimals,
        D18 pricePoolPerShare,
        D18 pricePoolPerAsset
    ) internal pure returns (uint256 quoteAmount) {
        uint256 poolAmount = pricePoolPerShare.mulUint256(shareAmount);
        return convertWithPrice(poolAmount, poolDecimals, assetDecimals, pricePoolPerAsset.reciprocal());
    }
}
