// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

/// [ERC-7726](https://eips.ethereum.org/EIPS/eip-7726): Common Quote Oracle
/// Interface for asset conversions.
interface IERC7726 {
    /// @notice Returns the value of baseAmount of base in quote terms, e.g. 10 ETH (base) in USDC (quote).
    /// @param base The asset in which the baseAmount is denominated in
    /// @param quote The asset in which the user needs to value the baseAmount
    /// @param baseAmount The amount of base in base terms.
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount);
}
