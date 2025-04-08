// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

/// @notice An IERC7726 valuation that allows to set a price that is only valid for the current transaction.
/// NOTE: Do not use it if the valuation lifetime is longer than the transaction.
interface ITransientValuation is IERC7726 {
    /// @notice The price has not been set for a pair base quote.
    error PriceNotSet(address base, address quote);

    /// @notice Set the price for the valuation to transform an amount from base to quote denomination.
    /// The price is the 1 amount of base denominated in quote.
    /// i.e: if base BTC and quote USDC, the price is 90_000 USDC per BTC
    /// Check IERC7726 for more info about base and quote
    function setPrice(address base, address quote, D18 price_) external;
}
