// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

//TODO Write documentation
interface IERC6909MetadataExtension {
    /// Errors ///
    error MissingName(uint256 tokenId);
    error MissingSymbol(uint256 tokenId);
    error MissingDecimals(uint256 tokenId);

    /// Functions ///
    function name(uint256 tokenId) external view returns (string memory);
    function symbol(uint256 tokenId) external view returns (string memory);
    function decimals(uint256 tokenId) external view returns (uint8);
}
