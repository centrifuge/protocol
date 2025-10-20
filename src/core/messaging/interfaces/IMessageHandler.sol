// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @notice Generic interface for entities that handle incoming messages
interface IMessageHandler {
    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @notice Handling incoming messages
    /// @param centrifugeId Source chain
    /// @param message Incoming message
    function handle(uint16 centrifugeId, bytes calldata message) external;
}
