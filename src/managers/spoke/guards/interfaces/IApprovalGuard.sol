// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

struct ApprovalEntry {
    address token;
    address spender;
}

interface IApprovalGuard {
    error NonZeroAllowance(address token, address spender, uint256 remaining);

    /// @notice Verify all listed token approvals from the caller are zero.
    /// @dev    Intended as a weiroll script tail command. The caller is the OnchainPM
    ///         (weiroll uses CALL), so `allowance(msg.sender, spender)` checks the
    ///         OnchainPM's outgoing approvals.
    /// @param entries Token/spender pairs to check.
    function checkZeroAllowances(ApprovalEntry[] calldata entries) external view;
}
