// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MathLib} from "src/misc/libraries/MathLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";

library ConversionLib {
    using MathLib for uint256;

    function convertWithPrice(uint256 baseAmount, uint8 baseDecimals, uint8 quoteDecimals, D18 price)
        external
        pure
        returns (uint256 quoteAmount)
    {
        if (baseDecimals == quoteDecimals) {
            return price.mulUint256(baseAmount);
        }

        return price.mulUint256(MathLib.mulDiv(baseAmount, 10 ** quoteDecimals, 10 ** baseDecimals));
    }

    function convertIntoPrice(uint128 amount, uint8 decimals)
    external
    pure
    returns (D18 price)
    {
        uint128 denom = (10 ** uint256(decimals)).toUint128();
        return d18(amount, denom);
    }
}
