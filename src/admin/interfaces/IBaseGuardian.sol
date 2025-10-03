// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IBaseGuardian
/// @notice Base interface for guardian contracts that manage protocol operations
/// @dev Both OpsGuardian and ProtocolGuardian implement this interface
/// @dev Each guardian has its own safe model with distinct responsibilities:
///      - ProtocolGuardian: safe for ongoing protocol governance and maintenance (high privilege)
///      - OpsGuardian: opsSafe for initial deployment and network setup (operational, low privilege)
interface IBaseGuardian {
    error NotTheAuthorizedSafe();
    error FileUnrecognizedParam();

    event File(bytes32 indexed what, address data);

    /// @notice Updates a contract parameter
    /// @dev Accepted parameter names vary by implementation:
    ///      - OpsGuardian: opsSafe, hub, multiAdapter
    ///      - ProtocolGuardian: safe, gateway, multiAdapter, sender
    /// @param what Name of the parameter to update
    /// @param data New value for the parameter
    function file(bytes32 what, address data) external;

    /// @notice Wire an adapter to a remote chain
    /// @dev Implementation semantics differ between guardians:
    ///      - OpsGuardian: First-time setup only, reverts if already wired, self-denies after
    ///      - ProtocolGuardian: No restrictions, can re-wire at any time
    /// @param adapter Address of the adapter to wire
    /// @param centrifugeId The chain ID to wire to
    /// @param data ABI-encoded adapter-specific configuration data
    function wire(address adapter, uint16 centrifugeId, bytes memory data) external;
}
