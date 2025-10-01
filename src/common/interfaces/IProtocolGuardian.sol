// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISafe} from "./ISafe.sol";
import {IAdapter} from "./IAdapter.sol";

interface IProtocolGuardian {
    error NotTheAuthorizedSafe();
    error NotTheAuthorizedSafeOrItsOwner();
    error FileUnrecognizedParam();

    event File(bytes32 indexed what, address data);

    /// @notice Return the linked Safe
    function safe() external view returns (ISafe);

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
    /// @param refund Address to receive unused gas refund
    function scheduleUpgrade(uint16 centrifugeId, address target, address refund) external payable;

    /// @notice Cancel an upgrade (scheduled rely) on a specific chain
    /// @dev    Only supports EVM targets today
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

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'safe', 'hub', 'sender', 'gateway', or 'multiAdapter' string value.
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;
}
