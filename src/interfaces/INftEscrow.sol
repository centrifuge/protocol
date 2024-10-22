// SPDX-License-Identifier: UNLICENSED
pragma solidity >= 0.8.0;

interface IERC6909 {
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool success);
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool success);
    function decimals(uint256 tokenId) external view returns (uint8);
    function balanceOf(address owner, uint256 id) external returns (uint256 amount);
}

/// Interface to handle an escrow of nfts
interface INftEscrow {
    event Locked(IERC6909 source, uint256 tokenId);
    event Unlocked(IERC6909 source, uint256 tokenId);
    event Attached(uint160 nftId, uint256 elementId);
    event Detached(uint160 nftId, uint256 elementId);

    /// @notice NFT already locked in the escrow.
    error AlreadyLocked();

    /// @notice NFT not locked in the escrow.
    error NotLocked();

    /// @notice The asset was already attached to an element.
    error AlreadyAttached();

    /// @notice The asset was not attached to an element.
    error NotAttached();

    /// @notice The asset can not be transfered to/from this contract.
    error CanNotBeTransferred();

    /// @notice The element is not valid. It has zero value.
    error InvalidElement();

    /// @notice Lock a collateral transfering one token to the contract.
    /// @param source The contract or collection where identify the `tokenId`
    /// @param tokenId The asset identification
    /// @param from Address allowed to transfer one token.
    /// @return nftId An unique identification of this `source` + `tokenId`
    function lock(IERC6909 source, uint256 tokenId, address from) external returns (uint160 nftId);

    /// @notice Lock a collateral transfering the token from the contract.
    /// @param source The contract or collection where identify the `tokenId`
    /// @param tokenId The asset identification
    /// @param to Address where the token will be transfered to.
    function unlock(IERC6909 source, uint256 tokenId, address to) external;

    /// @notice Associated an element to an already locked asset
    /// @param source The contract or collection where identify the `tokenId`
    /// @param tokenId The asset identification
    /// @param elementId An identification of the element associated to the asset
    /// @return nftId An unique identification of this `source` + `tokenId`
    function attach(IERC6909 source, uint256 tokenId, uint256 elementId) external returns (uint160 nftId);

    /// @notice Associated an element to a locked asset
    /// @param nftId The unique identification of the locked/attached nft
    function detach(uint160 nftId) external;

    /// @notice Compute the unique identification of the asset.
    /// @param source The contract or collection where identify the `tokenId`
    /// @param tokenId The asset identification
    /// @return nftId An unique identification of this `source` + `tokenId`
    function computeNftId(IERC6909 source, uint256 tokenId) external pure returns (uint160 nftId);
}
