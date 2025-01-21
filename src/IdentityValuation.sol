// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "src/types/D18.sol";

import {Conversion} from "src/libraries/Conversion.sol";

import {IERC7726, IERC7726Ext} from "src/interfaces/IERC7726.sol";
import {IIdentityValuation} from "src/interfaces/IIdentityValuation.sol";

contract IdentityValuation is IIdentityValuation {
    /// @inheritdoc IERC7726
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        return Conversion.convertWithPrice(baseAmount, base, quote, d18(1e18));
    }
}
