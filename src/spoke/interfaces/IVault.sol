// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0;

import {IVaultManager} from "src/spoke/interfaces/IVaultManager.sol";

enum VaultKind {
    /// @dev Refers to AsyncVault
    Async,
    /// @dev not yet supported
    Sync,
    /// @dev Refers to SyncDepositVault
    SyncDepositAsyncRedeem
}

/// @notice Interface for the all vault contracts
/// @dev Must be implemented by all vaults
interface IVault {
    /// @notice Returns the associated manager.
    function manager() external view returns (IVaultManager);

    /// @notice Checks whether the vault is partially (a)synchronous.
    ///
    /// @return vaultKind_ The kind of the vault
    function vaultKind() external view returns (VaultKind vaultKind_);
}
