// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

interface IGuardian {
    /// @notice Pause the protocol
    /// @dev callable by both safe and owners
    function pause() external;

    /// @notice Unpause the protocol
    /// @dev callable by safe only
    function unpause() external;

    /// @notice Schedule relying a target address on Root
    /// @dev callable by safe only
    function scheduleRely(address target) external;

    /// @notice Cancel a scheduled rely
    /// @dev callable by safe only
    function cancelRely(address target) external;

    /// @notice Dispute an gateway message recovery
    /// @dev callable by safe only
    function disputeMessageRecovery(address adapter, bytes32 messageHash) external;
}
