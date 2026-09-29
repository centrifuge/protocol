// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title  IAdapterWiring
/// @notice Interface for cross-chain bridge adapters that support wiring configuration
/// @dev    Only bridge adapters implement this interface.
///         Local adapters (e.g. StandbyAdapter) do not support wiring operations.
interface IAdapterWiring {
    /// @notice Wire the adapter to a remote chain
    /// @dev    If this is rewiring a previously wired centrifugeId, it might be necessary
    ///         to call first with an empty destination for the previous configuration, to reset.
    /// @param centrifugeId The chain ID to wire to
    /// @param data ABI-encoded adapter-specific configuration data
    function wire(uint16 centrifugeId, bytes memory data) external;

    /// @notice Whether `wire(centrifugeId, data)` would overwrite an existing binding
    /// @dev    `wire()` writes two mappings: the destination for `centrifugeId` and the source for the bridge
    ///         id carried in `data`. This is true when either is already set, so a first-time wire can neither
    ///         re-point a chain nor steal a bridge id that another chain's inbound messages arrive under. False
    ///         again after a reset (a `wire()` with an empty destination). The OpsGuardian may only wire
    ///         adapters for which this is false.
    /// @param centrifugeId The chain ID to check
    /// @param data ABI-encoded adapter-specific configuration data, as `wire()` would receive it
    function isWired(uint16 centrifugeId, bytes memory data) external view returns (bool);
}
