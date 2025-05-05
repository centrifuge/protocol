// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {IIdentityValuation} from "src/misc/interfaces/IIdentityValuation.sol";
import {IERC6909Decimals} from "src/misc/interfaces/IERC6909.sol";
import {BaseValuation} from "src/misc/BaseValuation.sol";

import {PricingLib} from "src/common/libraries/PricingLib.sol";

contract IdentityValuation is BaseValuation, IIdentityValuation {
    constructor(IERC6909Decimals erc6909, address deployer) BaseValuation(erc6909, deployer) {}

    /// @inheritdoc IERC7726
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        return PricingLib.convertWithPrice(baseAmount, _getDecimals(base), _getDecimals(quote), d18(1e18));
    }
}
