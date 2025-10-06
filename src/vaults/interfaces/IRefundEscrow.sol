// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @notice Simple escrow that can be used to deposit and withdraw native tokens
interface IRefundEscrow {
    /// @notice Dispatched when the given funds can not be withdrawed
    error CannotWithdraw();

    /// @notice Deposit `msg.value` funds to this contract
    function depositFunds() external payable;

    /// @notice Withdraw `value` funds to `to` address
    /// @param to The address to send the withdrawn funds to
    /// @param value The amount of native tokens to withdraw
    function withdrawFunds(address to, uint256 value) external;
}
