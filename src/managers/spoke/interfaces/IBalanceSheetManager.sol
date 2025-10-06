// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC165} from "../../../misc/interfaces/IERC165.sol";

/// @title  IDepositManager
/// @notice Interface for managing asset deposits into the balance sheet
interface IDepositManager is IERC165 {
    /// @notice Deposit assets into the balance sheet for an owner
    /// @param asset The asset contract address
    /// @param tokenId The token ID (0 for ERC20, non-zero for ERC6909)
    /// @param amount The amount to deposit
    /// @param owner The owner of the deposited assets
    function deposit(address asset, uint256 tokenId, uint128 amount, address owner) external;
}

/// @title  IWithdrawManager
/// @notice Interface for managing asset withdrawals from the balance sheet
interface IWithdrawManager is IERC165 {
    /// @notice Withdraw assets from the balance sheet to a receiver
    /// @param asset The asset contract address
    /// @param tokenId The token ID (0 for ERC20, non-zero for ERC6909)
    /// @param amount The amount to withdraw
    /// @param receiver The recipient of the withdrawn assets
    function withdraw(address asset, uint256 tokenId, uint128 amount, address receiver) external;
}
