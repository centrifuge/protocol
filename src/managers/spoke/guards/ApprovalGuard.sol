// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IApprovalGuard, ApprovalEntry} from "./interfaces/IApprovalGuard.sol";

import {IERC20} from "../../../misc/interfaces/IERC20.sol";

/// @title  ApprovalGuard
/// @notice Stateless guard that verifies all listed ERC20 approvals from the caller are zero.
///         Used as a tail command in weiroll scripts to ensure no dangling approvals remain
///         after execution.
contract ApprovalGuard is IApprovalGuard {
    /// @inheritdoc IApprovalGuard
    function checkZeroAllowances(ApprovalEntry[] calldata entries) external view {
        for (uint256 i; i < entries.length; i++) {
            uint256 remaining = IERC20(entries[i].token).allowance(msg.sender, entries[i].spender);
            require(remaining == 0, NonZeroAllowance(entries[i].token, entries[i].spender, remaining));
        }
    }
}
