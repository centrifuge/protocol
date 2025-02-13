// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IEscrow {
    // --- Events ---
    event Approve(address indexed token, address indexed spender, uint256 value);

    // --- Token approvals ---
    /// @notice sets the allowance of `spender` to `type(uint256).max` if it is currently 0
    function approveMax(address token, address spender) external;

    /// @notice sets the allowance of `spender` to 0
    function unapprove(address token, address spender) external;
}
