// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC6909} from "src/interfaces/ERC6909/IERC6909.sol";
import {IERC6909URIExtension} from "src/interfaces/ERC6909/IERC6909URIExtension.sol";

interface IERC6909Centrifuge is IERC6909, IERC6909URIExtension {
    /// Errors
    error UnknownTokenId(address owner, uint256 tokenId);
    error EmptyOwner();
    error EmptyAmount();
    error EmptyURI();
    error MaxSupplyReached();
    error Burn_InsufficientBalance(address owner, uint256 tokenId);
    error LessThanMinimalDecimal(uint8 minimal, uint8 actual);

    /// Functions
    /// @notice             Get total supply of a given token.
    /// @dev                To increase the total supply call mint(address owner, uint256 tokenId, uint256 amount).
    ///                     The total supply will be increased by amount and cannot go over type(uint256).max.
    /// @param tokenId      Token Id.
    function totalSupply(uint256 tokenId) external returns (uint256);

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
    /// @param amount       Amount of newly created supply.
    /// @return tokenId     Id of the newly minted token.
    function mint(address owner, string memory tokenURI, uint256 amount) external returns (uint256 tokenId);

    /// @dev                Used to increase the supply for a given tokenId.
    ///
    /// @param owner        Creates supply of a given tokenId by amount for owner.
    /// @param tokenId      The tokenId  of the item which supply will be increased.
    /// @param amount       Amount by which the supply for tokenId of owner is increased by.
    /// @return             New supply of item with tokenId.
    function mint(address owner, uint256 tokenId, uint256 amount) external returns (uint256);

    /// @notice             Destroy supply of a given tokenId by amount.
    /// @dev                The msg.sender MUST be the owner.
    ///
    /// @param tokenId      Item which have reduced supply.
    /// @param amount       Amount to be burnt.
    /// @return             Amount that is left after burning the amount tokens.
    function burn(uint256 tokenId, uint256 amount) external returns (uint256);
}
