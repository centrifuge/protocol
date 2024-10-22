// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >= 0.8.0;

import {IERC7726, IERC7726} from "src/interfaces/IERC7726.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MathLib} from "src/libraries/MathLib.sol";

interface IOracle is IERC7726 {
    /// @notice Dispatched when the action is not performed by the required feeder.
    error NotValidFeeder();

    /// @notice Dispatched when the base/quote pair has never been fed.
    error NoQuote();

    /// @notice Emitted when the contract is fed with a new quote amount.
    event NewQuoteSet(address indexed base, address indexed quote, uint256 quoteAmount, uint64 referenceTime);

    /// @notice Feed the contract with a new base -> quote relation.
    /// @param base The identification of the base element. If it corresponds to an ERC20, the internal computations
    /// will use the attached decimals of that asset. If not 18 decimals will be used.
    /// @param quote Same as `base` but for `quote`.
    /// @param quoteAmount The amount of 1 wei of base amount represented as quote units.
    function setQuote(address base, address quote, uint256 quoteAmount) external;
}

interface IOracleFactory {
    /// @notice Emitted when a new oracle contract is deployed.
    event NewOracleDeployed(address where);

    /// @notice Deploy a new oracle contract for an specific feeder.
    /// @param feeder The account that will be able to fed values in the contract.
    /// @param salt Extra bytes to generate different address for the same feeder.
    function deploy(address feeder, bytes32 salt) external returns (IOracle);

    /// @notice Retuns the deterministic contract address for a feeder.
    /// @param feeder The account that will be able to fed values in the contract.
    /// @param salt Extra bytes to generate different address for the same feeder.
    function getAddress(address feeder, bytes32 salt) external view returns (address);
}
