// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "src/common/interfaces/IAdapter.sol";

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

    /// @notice Schedule an upgrade (scheduled rely) on another chain
    /// @dev    Only supports EVM targets today
    function scheduleUpgrade(uint16 chainId, address target) external;

    /// @notice Cancel an upgrade (scheduled rely) on another chain
    /// @dev    Only supports EVM targets today
    function cancelUpgrade(uint16 chainId, address target) external;

    /// @notice Initiate message recovery on another chain
    /// @dev    Only supports EVM targets today
    function initiateMessageRecovery(uint16 chainId, uint16 adapterChainId, IAdapter adapter, bytes32 hash) external;

    /// @notice Dispute message recovery on another chain
    /// @dev    Only supports EVM targets today
    function disputeMessageRecovery(uint16 chainId, uint16 adapterChainId, IAdapter adapter, bytes32 hash) external;
}
