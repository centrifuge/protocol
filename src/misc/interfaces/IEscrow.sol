// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title  Escrow for holding assets
interface IEscrow {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    /// @notice Emitted when an authTransferTo is made
    /// @dev Needed as allowances increase attack surface
    event AuthTransferTo(address indexed asset, uint256 indexed tokenId, address receiver, uint256 value);

    /// @notice Emitted when the escrow has insufficient balance for an action - virtual or actual balance
    error InsufficientBalance(address asset, uint256 tokenId, uint256 value, uint256 balance);

    /// @notice Transfers assets from the escrow to a receiver address
    /// @param asset The address of the asset to transfer
    /// @param tokenId The token ID of the asset (0 for ERC20, non-zero for ERC6909)
    /// @param receiver The address receiving the transferred assets
    /// @param value The amount of assets to transfer
    function authTransferTo(address asset, uint256 tokenId, address receiver, uint256 value) external;
}
