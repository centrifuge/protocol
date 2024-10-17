// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

/// [ERC-7726](https://eips.ethereum.org/EIPS/eip-7726): Common Quote Oracle
/// Interface for data feeds providing the relative value of assets.
interface IERC7726 {
    /// @notice Returns the value of `baseAmount` of `base` in quote `terms`.
    /// It's rounded towards 0 and reverts if overflow
    /// @param base The asset that the user needs to know the value for
    /// @param quote The asset in which the user needs to value the base
    /// @param baseAmount An amount of base in quote terms
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount);
}

/// Extension for IERC7726
interface IERC7726Ext is IERC7726 {
    /// @notice extension function that acts as `getQuote()` but provides an indicative value instead.
    function getIndicativeQuote(uint256 baseAmount, address base, address quote)
        external
        view
        returns (uint256 quoteAmount);
}
