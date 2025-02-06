// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Generic interface for entities that receives messages
interface IMessageHandler {
    /// @notice Handling incoming messages.
    /// @param message Incoming message
    function handle(bytes calldata message) external;
}
