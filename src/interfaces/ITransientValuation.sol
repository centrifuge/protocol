// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/types/D18.sol";
import {IERC7726Ext} from "src/interfaces/IERC7726.sol";

/// @notice An IERC7726 valuation that allows to set a price that is only valid for the current transaction.
/// NOTE: Do not use it if the valuation lifetime is longer than the transaction.
interface ITransientValuation is IERC7726Ext {
    /// @notice Set the price for the valuation.
    /// The price is the 1 amount of base denominated in quote.
    /// i.e: if base BTC and quote USDC, the price is 90_000 USDC per BTC
    /// Check IERC7726 for more info about base and quote
    function setPrice(D18 price) external;
}
