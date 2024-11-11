// SPDX-License-Identifier: UNLICENSED
pragma solidity >= 0.8.0;

import {IERC6909} from "src/interfaces/ERC6909/IERC6909.sol";

/// Interface to handle an escrow of nfts
interface INftEscrow {
    event Locked(IERC6909 indexed source, uint256 indexed tokenId);
    event Unlocked(IERC6909 indexed source, uint256 indexed tokenId);

    /// @notice NFT already locked in the escrow.
    error AlreadyLocked();

    /// @notice NFT not locked in the escrow.
    error NotLocked();

    /// @notice The asset can not be transfered to/from this contract.
    error CanNotBeTransferred();

    /// @notice Lock a nft transfering one token to the contract.
    /// No more tokens from the same `tokenId` can be sent to the escrow until it's locked.
    /// @param source The contract or collection where identify the `tokenId`
    /// @param tokenId The asset identification
    /// @param from Address allowed to transfer one token.
    function lock(IERC6909 source, uint256 tokenId, address from) external;

    /// @notice Unlock a nft transfering back the token from the contract.
    /// The same `tokenId` can be locked again
    /// @param source The contract or collection where identify the `tokenId`
    /// @param tokenId The asset identification
    /// @param to Address where the token will be transfered to.
    function unlock(IERC6909 source, uint256 tokenId, address to) external;
}
