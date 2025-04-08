// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {IERC165} from "forge-std/interfaces/IERC165.sol";

interface IERC6909 is IERC165 {
    error EmptyOwner();
    error EmptyAmount();
    error InvalidTokenId();
    error InsufficientBalance(address owner, uint256 tokenId);
    error InsufficientAllowance(address sender, uint256 tokenId);

    event OperatorSet(address indexed owner, address indexed operator, bool approved);
    event Approval(address indexed owner, address indexed spender, uint256 indexed tokenId, uint256 amount);
    event Transfer(address caller, address indexed from, address indexed to, uint256 indexed tokenId, uint256 amount);

    /// @notice           Owner balance of a tokenId.
    /// @param owner      The address of the owner.
    /// @param tokenId    The id of the token.
    /// @return amount    The balance of the token.
    function balanceOf(address owner, uint256 tokenId) external view returns (uint256 amount);

    /// @notice           Spender allowance of a tokenId.
    /// @param owner      The address of the owner.
    /// @param spender    The address of the spender.
    /// @param tokenId    The id of the token.
    /// @return amount    The allowance of the token.
    function allowance(address owner, address spender, uint256 tokenId) external view returns (uint256 amount);

    /// @notice           Checks if a spender is approved by an owner as an operator.
    /// @param owner      The address of the owner.
    /// @param spender    The address of the spender.
    /// @return approved  The approval status.
    function isOperator(address owner, address spender) external view returns (bool approved);

    /// @notice           Transfers an amount of a tokenId from the caller to a receiver.
    /// @param receiver   The address of the receiver.
    /// @param tokenId    The id of the token.
    /// @param amount     The amount of the token.
    /// @return bool      True, always, unless the function reverts.
    function transfer(address receiver, uint256 tokenId, uint256 amount) external returns (bool);

    /// @notice           Transfers an amount of a tokenId from a sender to a receiver.
    /// @param sender     The address of the sender.
    /// @param receiver   The address of the receiver.
    /// @param tokenId    The id of the token.
    /// @param amount     The amount of the token.
    /// @return bool      True, always, unless the function reverts.
    function transferFrom(address sender, address receiver, uint256 tokenId, uint256 amount) external returns (bool);

    /// @notice           Approves an amount of a tokenId to a spender.
    /// @param spender    The address of the spender.
    /// @param tokenId    The id of the token.
    /// @param amount     The amount of the token.
    /// @return bool      True, always.
    function approve(address spender, uint256 tokenId, uint256 amount) external returns (bool);

    /// @notice           Sets or removes an operator for the caller.
    /// @param operator   The address of the operator.
    /// @param approved   The approval status.
    /// @return bool      True, always.
    function setOperator(address operator, bool approved) external returns (bool);
}

interface IERC6909URIExt {
    event TokenURISet(uint256 indexed tokenId, string uri);
    event ContractURISet(address indexed target, string uri);

    error EmptyURI();

    /// @return uri     Returns the common token URI.
    function contractURI() external view returns (string memory);

    /// @dev            Returns empty string if tokenId does not exist.
    ///                 MAY implemented to throw MissingURI(tokenId) error.
    /// @param tokenId  The token to query URI for.
    /// @return uri     A string representing the uri for the specific tokenId.
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

interface IERC6909NFT is IERC6909, IERC6909URIExt {
    error UnknownTokenId(address owner, uint256 tokenId);
    error LessThanMinimalDecimal(uint8 minimal, uint8 actual);

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

/// @notice Extension of ERC6909 Standard for tracking total supply
interface IERC6909TotalSupplyExt {
    /// @notice         The totalSupply for a token id.
    ///
    /// @param tokenId  Id of the token
    /// @return supply  Total supply for a given `tokenId`
    function totalSupply(uint256 tokenId) external returns (uint256 supply);
}

interface IERC6909Decimals {
    /// @notice             Used to retrieve the decimals of an asset
    /// @dev                address is used but the value corresponds to a AssetId
    function decimals(uint256 assetId) external view returns (uint8);
}

interface IERC6909MetadataExt is IERC6909Decimals {
    /// @notice             Used to retrieve the decimals of an asset
    /// @dev                address is used but the value corresponds to a AssetId
    function decimals(uint256 assetId) external view returns (uint8);

    /// @notice             Used to retrieve the name of an asset
    /// @dev                address is used but the value corresponds to a AssetId
    function name(uint256 assetId) external view returns (string memory);

    /// @notice             Used to retrieve the symbol of an asset
    /// @dev                address is used but the value corresponds to a AssetId
    function symbol(uint256 assetId) external view returns (string memory);
}

interface IERC6909Fungible is IERC6909 {
    /// @notice             Mint new tokens for a specific tokenid and assign them to an owner
    ///
    /// @param owner        Creates supply of a given `tokenId` by `amount` for owner.
    /// @param tokenId      Id of the item
    /// @param amount       Adds `amount` to the total supply of the given `tokenId`
    function mint(address owner, uint256 tokenId, uint256 amount) external;

    /// @notice             Destroy supply of a given tokenId by amount.
    /// @dev                The msg.sender MUST be the owner.
    ///
    /// @param owner        Owner of the `tokenId`
    /// @param tokenId      Id of the item.
    /// @param amount       Subtract `amount` from the total supply of the given `tokenId`
    function burn(address owner, uint256 tokenId, uint256 amount) external;

    /// @notice             Enforces a transfer from `spender` point of view.
    ///
    ///
    /// @param sender       The owner of the `tokenId`
    /// @param receiver     Address of the receiving party
    /// @param tokenId      Token Id
    /// @param amount       Amount to be transferred
    function authTransferFrom(address sender, address receiver, uint256 tokenId, uint256 amount)
        external
        returns (bool);
}

/// @dev  A factory contract to deploy new collateral contracts implementing IERC6909.
interface IERC6909Factory {
    /// Events
    event NewTokenDeployment(address indexed owner, address instance);

    /// @notice       Deploys new install of a contract that implements IERC6909.
    /// @dev          Factory should deploy deterministically if possible.
    ///
    /// @param owner  Owner of the deployed collateral contract which has initial full rights.
    /// @param salt   Used to make a deterministic deployment.
    /// @return       An address of the newly deployed contract.
    function deploy(address owner, bytes32 salt) external returns (address);

    /// @notice       Generates a new deterministic address based on the owner and the salt.
    ///
    /// @param owner  Owner of the deployed collateral contract which has initial full rights.
    /// @param salt   Used to make a deterministic deployment.
    /// @return       An address of the newly deployed contract.
    function previewAddress(address owner, bytes32 salt) external returns (address);
}
