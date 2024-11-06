// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC6909} from "src/interfaces/ERC6909/IERC6909.sol";
import {IERC6909URIExtension} from "src/interfaces/ERC6909/IERC6909URIExtension.sol";

interface IERC6909NFT is IERC6909, IERC6909URIExtension {
    /// Errors
    error UnknownTokenId(address owner, uint256 tokenId);
    error LessThanMinimalDecimal(uint8 minimal, uint8 actual);

    /// Functions
    /// @notice             Provide URI for a specific tokenId.
    /// @param tokenId      Token Id.
    /// @param URI          URI to a document defining the collection as a whole.
    function setTokenURI(uint256 tokenId, string memory URI) external;

    /// @dev                Optional method to set up the contract URI if needed.
    /// @param URI          URI to a document defining the collection as a whole.
    function setContractURI(string memory URI) external;

    /// @notice             Mint new tokens for a given owner and sets tokenURI.
    /// @dev                For non-fungible tokens, call with amount = 1, for fungible it could be any amount.
    ///                     TokenId is auto incremented by one.
    ///
    /// @param owner        Creates supply of a given tokenId by amount for owner.
    /// @param tokenURI     URI fortestBurningToken the newly minted token.
    /// @return tokenId     Id of the newly minted token.
    function mint(address owner, string memory tokenURI) external returns (uint256 tokenId);

    /// @notice             Destroy supply of a given tokenId by amount.
    /// @dev                The msg.sender MUST be the owner.
    ///
    /// @param tokenId      Item which have reduced supply.
    function burn(uint256 tokenId) external;
}
