// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC6909} from "src/interfaces/ERC6909/IERC6909.sol";

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
