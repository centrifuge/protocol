// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity = 0.8.28;

import {IERC7726, IERC7726Ext} from "src/interfaces/IERC7726.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract Oracle is IERC7726Ext {
    error NotValidFeeder();
    error ValueNotFound();

    event Fed(address indexed base, address indexed quote, uint256 quoteAmount);

    struct Value {
        /// Price of one base in quote denomination
        uint256 amount;
        /// Timestamp when the value was fed
        uint64 referenceTime;
    }

    address feeder;
    mapping(address base => mapping(address quote => Value)) public values;

    modifier onlyFeeder() {
        require(msg.sender == feeder, NotValidFeeder());
        _;
    }

    constructor(address feeder_) {
        feeder = feeder_;
    }

    /// @notice Feed the system with a new base -> quote relation.
    /// @param base The identification of the base element
    /// @param quote The identification of the quote element
    /// @param quoteAmount The amount of 1 wei of base amount represented as quote units.
    function setQuote(address base, address quote, uint256 quoteAmount) external onlyFeeder {
        values[base][quote] = Value(quoteAmount, uint64(block.timestamp));

        emit Fed(base, quote, quoteAmount);
    }

    /// @inheritdoc IERC7726
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        Value storage quoteValue = values[base][quote];
        require(quoteValue.referenceTime > 0, ValueNotFound());

        return baseAmount * quoteValue.amount;
    }

    /// @inheritdoc IERC7726Ext
    function getIndicativeQuote(uint256 baseAmount, address base, address quote)
        external
        view
        returns (uint256 quoteAmount)
    {
        //TODO
    }
}
