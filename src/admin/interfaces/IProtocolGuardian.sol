// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IBaseGuardian} from "./IBaseGuardian.sol";

import {IAdapter} from "../../core/messaging/interfaces/IAdapter.sol";

interface IProtocolGuardian is IBaseGuardian {
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

    /// @notice Schedule an upgrade (scheduled rely) on a specific chain
    /// @dev    Only supports EVM targets today
    /// @param centrifugeId The chain ID where the upgrade will be scheduled
    /// @param target The address to schedule as a ward
    /// @param refund Address to receive unused gas refund
    function scheduleUpgrade(uint16 centrifugeId, address target, address refund) external payable;

    /// @notice Cancel an upgrade (scheduled rely) on a specific chain
    /// @dev    Only supports EVM targets today
    /// @param centrifugeId The chain ID where the upgrade will be cancelled
    /// @param target The address to cancel the scheduled rely for
    /// @param refund Address to receive unused gas refund
    function cancelUpgrade(uint16 centrifugeId, address target, address refund) external payable;

    /// @notice Recover tokens on a specific chain
    /// @dev    Only supports EVM targets today
    /// @param refund Address to receive unused gas refund
    function recoverTokens(
        uint16 centrifugeId,
        address target,
        address token,
        uint256 tokenId,
        address to,
        uint256 amount,
        address refund
    ) external payable;

    /// @notice Set adapters locally for global pool
    /// @dev Local-only operation, does not send cross-chain message
    /// @param centrifugeId Target chain ID to configure adapters on
    /// @param adapters Array of adapter contract addresses
    /// @param threshold Minimum number of adapters that must agree
    /// @param recoveryIndex Index of the recovery adapter in the array
    function setAdapters(uint16 centrifugeId, IAdapter[] calldata adapters, uint8 threshold, uint8 recoveryIndex)
        external;

    /// @notice Block or unblock outgoing messages for global pool
    /// @dev Local-only operation for fast emergency response
    /// @param centrifugeId Target chain ID to block/unblock
    /// @param isBlocked True to block outgoing messages, false to unblock
    function blockOutgoing(uint16 centrifugeId, bool isBlocked) external;
}
