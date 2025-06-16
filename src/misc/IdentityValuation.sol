// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {d18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IERC6909Decimals} from "src/misc/interfaces/IERC6909.sol";
import {IIdentityValuation} from "src/misc/interfaces/IIdentityValuation.sol";

import {AssetId} from "src/common/types/AssetId.sol";
import {BaseValuation} from "src/common/BaseValuation.sol";
import {PricingLib} from "src/common/libraries/PricingLib.sol";
import {IValuation} from "src/common/interfaces/IValuation.sol";

contract IdentityValuation is BaseValuation, IIdentityValuation {
    using MathLib for *;

    constructor(IERC6909Decimals erc6909, address deployer) BaseValuation(erc6909, deployer) {}

    /// @inheritdoc IValuation
    function getQuote(uint128 baseAmount, AssetId base, AssetId quote) external view returns (uint128 quoteAmount) {
        return PricingLib.convertWithPrice(baseAmount, _getDecimals(base), _getDecimals(quote), d18(1e18));
    }
}
