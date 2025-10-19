// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IAdapterWiring
/// @notice Interface for cross-chain bridge adapters that support wiring configuration
/// @dev Only bridge adapters (Axelar, LayerZero, Wormhole) implement this interface.
///      Local adapters (Recovery, Local) do not support wiring operations.
interface IAdapterWiring {
    /// @notice Wire the adapter to a remote chain
    /// @dev    If this is rewiring a previously wired centrifugeId, it might be necessary
    ///         to call first with an empty destination for the previous configuration, to reset.
    /// @param centrifugeId The chain ID to wire to
    /// @param data ABI-encoded adapter-specific configuration data
    function wire(uint16 centrifugeId, bytes memory data) external;

    /// @notice Check if the adapter is wired to a specific chain
    /// @param centrifugeId The chain ID to check
    /// @return True if the adapter is already wired to this chain
    function isWired(uint16 centrifugeId) external view returns (bool);
}
