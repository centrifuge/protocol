// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// [ERC-7726](https://eips.ethereum.org/EIPS/eip-7726): Common Quote Oracle
/// Interface for data feeds providing the relative value of assets.
interface IERC7726 {
    /// @notice Returns the value of baseAmount of base in quote terms, e.g. 10 ETH (base) in USDC (quote). It's rounded
    /// towards 0 and reverts if it overflows.
    /// @param base The asset in which the baseAmount is denominated in
    /// @param quote The asset in which the user needs to value the baseAmount
    /// @param baseAmount An amount of base in quote terms
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount);
}
