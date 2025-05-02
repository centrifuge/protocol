// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "src/misc/types/D18.sol";

import {PricingLib} from "src/common/libraries/PricingLib.sol";
import {TransientStorageLib} from "src/misc/libraries/TransientStorageLib.sol";
import {ReentrancyProtection} from "src/misc/ReentrancyProtection.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {IERC6909Decimals} from "src/misc/interfaces/IERC6909.sol";

import {BaseValuation} from "src/misc/BaseValuation.sol";

contract MockValuation is BaseValuation, ReentrancyProtection {
    constructor(IERC6909Decimals erc6909) BaseValuation(erc6909, msg.sender) {}

    mapping(address base => mapping(address quote => D18)) public price;

    function setPrice(address base, address quote, D18 price_) external protected {
        price[base][quote] = price_;
        price[quote][base] = price_.reciprocal();
    }

    /// @inheritdoc IERC7726
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        D18 price_ = price[base][quote];
        require(D18.unwrap(price_) != 0, "Price not set");

        return PricingLib.convertWithPrice(baseAmount, _getDecimals(base), _getDecimals(quote), price_);
    }
}
