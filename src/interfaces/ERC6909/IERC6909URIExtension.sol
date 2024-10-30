// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

interface IERC6909URIExtension {
    /// Events ///
    event TokenURISet(uint256 indexed tokenId, string uri);
    event ContractURISet(address indexed target, string uri);

    /// Functions ///

    /// @return uri     Returns the common token URI.
    function contractURI() external view returns (string memory);

    /// @dev            Returns empty string if tokenId does not exist.
    ///                 MAY implemented to throw MissingURI(tokenId) error.
    /// @param tokenId  The token to query URI for.
    /// @return uri     A string representing the uri for the specific tokenId.
    function tokenURI(uint256 tokenId) external view returns (string memory);
}
