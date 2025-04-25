// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "src/misc/types/D18.sol";

import {PricingLib} from "src/common/libraries/PricingLib.sol";
import {TransientStorageLib} from "src/misc/libraries/TransientStorageLib.sol";
import {ReentrancyProtection} from "src/misc/ReentrancyProtection.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {IERC6909Decimals} from "src/misc/interfaces/IERC6909.sol";

import {BaseValuation} from "src/misc/BaseValuation.sol";

contract TransientValuation is BaseValuation, ReentrancyProtection {
    using TransientStorageLib for bytes32;

    /// @notice The price has not been set for a pair base quote.
    error PriceNotSet(address base, address quote);

    constructor(IERC6909Decimals erc6909) BaseValuation(erc6909, msg.sender) {}

    function setPrice(address base, address quote, D18 price) external protected {
        bytes32 slot = keccak256(abi.encode(base, quote));
        slot.tstore(uint256(price.inner()));

        // Only store price if base and quote differ
        if (base == quote) {
            return;
        }

        // We assume symmetric prices
        slot = keccak256(abi.encode(quote, base));
        slot.tstore(uint256(price.reciprocal().inner()));
    }

    /// @inheritdoc IERC7726
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        bytes32 slot = keccak256(abi.encode(base, quote));
        D18 price = d18(uint128(slot.tloadUint256()));

        require(D18.unwrap(price) != 0, PriceNotSet(base, quote));

        return PricingLib.convertWithPrice(baseAmount, _getDecimals(base), _getDecimals(quote), price);
    }
}
