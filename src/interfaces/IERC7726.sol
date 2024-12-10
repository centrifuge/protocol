// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.6.2;

/// [ERC-7726](https://eips.ethereum.org/EIPS/eip-7726): Common Quote Oracle
/// Interface for asset conversions.
interface IERC7726 {
    /// @notice Returns the value of `baseAmount` of `base` in `quote` terms.
    /// @param base The asset the user provides the amount.
    /// @param quote The asset that the user needs to know the value for.
    /// @param baseAmount An amount of `base` in `base` terms.
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount);
}
