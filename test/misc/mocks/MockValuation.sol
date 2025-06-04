// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";

import {TransientStorageLib} from "src/misc/libraries/TransientStorageLib.sol";
import {ReentrancyProtection} from "src/misc/ReentrancyProtection.sol";
import {IERC6909Decimals} from "src/misc/interfaces/IERC6909.sol";

import {IValuation} from "src/common/interfaces/IValuation.sol";
import {BaseValuation} from "src/common/BaseValuation.sol";
import {PricingLib} from "src/common/libraries/PricingLib.sol";
import {AssetId} from "src/common/types/AssetId.sol";

struct Price {
    D18 value;
    bool valid;
}

contract MockValuation is BaseValuation, ReentrancyProtection {
    using MathLib for *;

    constructor(IERC6909Decimals erc6909) BaseValuation(erc6909, msg.sender) {}

    mapping(AssetId base => mapping(AssetId quote => Price)) public price;

    function setPrice(AssetId base, AssetId quote, D18 price_) external protected {
        price[base][quote] = Price(price_, true);
        price[quote][base] = Price(price_.reciprocal(), true);
    }

    /// @inheritdoc IValuation
    function getQuote(uint128 baseAmount, AssetId base, AssetId quote) external view returns (uint128 quoteAmount) {
        Price memory price_ = price[base][quote];
        require(price_.valid, "Price not set");

        return
            PricingLib.convertWithPrice(baseAmount, _getDecimals(base), _getDecimals(quote), price_.value).toUint128();
    }
}
