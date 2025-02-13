// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0;

interface IEscrow {
    // --- Events ---
    event Approve(address indexed token, address indexed spender, uint256 value);

    // --- Token approvals ---
    /// @notice sets the allowance of `spender` to `type(uint256).max` if it is currently 0
    function approveMax(address token, address spender) external;

    /// @notice sets the allowance of `spender` to 0
    function unapprove(address token, address spender) external;
}
