// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC7726} from "src/interfaces/IERC7726.sol";
import {AssetId} from "src/types/AssetId.sol";
import {D18} from "src/types/D18.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {ITransientValuation} from "src/interfaces/ITransientValuation.sol";
import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";

contract TransientValuation is ITransientValuation {
    using MathLib for uint256;

    /// Temporal price set and used to obtain the quote.
    D18 public /*TODO: transient*/ price;

    /// @inheritdoc ITransientValuation
    function setPrice(D18 price_) external {
        price = price_;
    }

    /// @inheritdoc IERC7726
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        uint8 baseDecimals = IERC20Metadata(base).decimals();
        uint8 quoteDecimals = IERC20Metadata(quote).decimals();

        if (baseDecimals == quoteDecimals) {
            return price.mulUint256(baseAmount);
        }

        return price.mulUint256(MathLib.mulDiv(baseAmount, 10 ** quoteDecimals, 10 ** baseDecimals));
    }
}
