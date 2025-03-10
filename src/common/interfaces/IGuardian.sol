// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface ISafe {
    function isOwner(address signer) external view returns (bool);
}

interface IGuardian {
    error NotTheAuthorizedSafe();
    error NotTheAuthorizedSafeOrItsOwner();

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
