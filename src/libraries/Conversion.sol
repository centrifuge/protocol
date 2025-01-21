// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {D18} from "src/types/D18.sol";

library Conversion {
    function convertWithPrice(uint256 baseAmount, address base, address quote, D18 price)
        external
        view
        returns (uint256 quoteAmount)
    {
        uint8 baseDecimals = IERC20Metadata(base).decimals();
        uint8 quoteDecimals = IERC20Metadata(quote).decimals();

        if (baseDecimals == quoteDecimals) {
            return price.mulUint256(baseAmount);
        }

        return price.mulUint256(MathLib.mulDiv(baseAmount, 10 ** quoteDecimals, 10 ** baseDecimals));
    }
}
