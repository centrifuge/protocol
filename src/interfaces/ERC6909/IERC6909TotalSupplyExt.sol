// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @notice Extension of ERC6909 Standard for tracking total supply
interface IERC6909TotalSupplyExt {
    /// @notice         The totalSupply for a token id.
    ///
    /// @param tokenId  Id of the token
    /// @return supply  Total supply for a given `tokenId`
    function totalSupply(uint256 tokenId) external returns (uint256 supply);
}
