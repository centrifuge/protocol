// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

interface IERC6909URIExtension {
    /// Errors ///

    /// @notice         Thrown when trying to set the contract URI to empty string
    error MissingContractURI();

    /// @notice         Thrown when there is a missing URI for the tokenId
    ///                 being added.
    /// @dev            Could be used to be thrown when a non-existing tokenId is queried
    /// @param tokenId  The token id being added to the collection
    error MissingTokenURI(uint256 tokenId);

    /// Events ///
    event TokenURI(uint256 indexed tokenId, string uri);
    event ContractURI(address indexed target, string uri);

    /// Functions ///

    /// @return uri     Returns the common token URI
    function contractURI() external view returns (string memory);

    /// @dev            Returns empty string if tokenId does not exist.
    ///                 MAY implemented to throw MissingURI(tokenId) error.
    /// @param tokenId  The token to query URI for.
    /// @return uri     A string representing the uri for the specific tokenId.
    function tokenURI(uint256 tokenId) external view returns (string memory);
}
