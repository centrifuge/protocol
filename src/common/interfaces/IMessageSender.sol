// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

/// @notice Generic interface for entities that handles outgoing messages
interface IMessageSender {
    /// @notice Handling outgoing messages.
    /// @param centrifugeId Destination chain
    function send(uint16 centrifugeId, bytes calldata message) external;
}
