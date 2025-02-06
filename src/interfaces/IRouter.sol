// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Generic interface for entities that represents routers
interface IRouter {
    /// @notice Handling outgoing messages.
    /// @param chainId Destination chain
    /// @param message Outgoing message
    function send(uint32 chainId, bytes calldata message) external;
}
