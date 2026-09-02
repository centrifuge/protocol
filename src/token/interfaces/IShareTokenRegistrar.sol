// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title  IShareTokenRegistrar
/// @notice Registrar for the protocol's own ShareToken standard (ERC20 + ERC1404 with transfer hooks).
interface IShareTokenRegistrar {
    /// @notice Hub-driven, envoy-gated operations selected by the leading discriminant of the `fromHub` payload.
    enum RegistrarCall {
        /// @notice Set the transfer hook of a share class token.
        SetHook,
        /// @notice Set (or clear with address(0)) the ERC-7575 vault of a share class token for an asset.
        SetVault,
        /// @notice Grant or revoke a ward on a share class token.
        UpdateWard
    }

    event File(bytes32 indexed what, address data);

    error OldHook();
    error InvalidHook();
    error OldMetadata();
    error NotEnvoy();
    error NotRegistrar();
    error NonZeroTokenId();
    error VaultMismatch();
    error UnexpectedValue();
    error CannotDenySelf();
    error UnknownRegistrarCall();
    error FileUnrecognizedParam();

    /// @notice Sets a dependency (`envoy`, `spokeRegistry`)
    function file(bytes32 what, address data) external;

    /// @notice Root authority that is granted ward permissions on newly deployed share tokens
    function root() external view returns (address);

    /// @notice The Envoy that is the sole authorized caller of `fromHub`
    function envoy() external view returns (address);
}
