// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IIdentityValuation} from "./interfaces/IIdentityValuation.sol";

import {d18} from "../misc/types/D18.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {IERC6909Decimals} from "../misc/interfaces/IERC6909.sol";

import {AssetId} from "../common/types/AssetId.sol";
import {BaseValuation} from "../common/BaseValuation.sol";
import {PricingLib} from "../common/libraries/PricingLib.sol";
import {IValuation} from "../common/interfaces/IValuation.sol";

contract IdentityValuation is BaseValuation, IIdentityValuation {
    using MathLib for *;

    constructor(IERC6909Decimals erc6909, address deployer) BaseValuation(erc6909, deployer) {}

    /// @inheritdoc IValuation
    function getQuote(uint128 baseAmount, AssetId base, AssetId quote) external view returns (uint128 quoteAmount) {
        return PricingLib.convertWithPrice(baseAmount, _getDecimals(base), _getDecimals(quote), d18(1e18));
    }
}
