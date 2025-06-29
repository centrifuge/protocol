// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @notice Generic interface for entities that handles outgoing messages
interface IMessageSender {
    /// @notice Handling outgoing messages.
    /// @param centrifugeId Destination chain
    function send(uint16 centrifugeId, bytes calldata message) external;
}
