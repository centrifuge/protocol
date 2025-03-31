// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

enum VaultKind {
    /// @dev Refers to AsyncVault
    Async,
    /// @dev not yet supported
    Sync,
    /// @dev Refers to SyncDepositVault
    SyncDepositAsyncRedeem
}

/// @title  IVaultManager Interface
/// @notice Interface for the vault manager contract, needed to link/unlink vaults correctly.
/// @dev Must be implemented by all vault managers
interface IVaultManager {
    /// @notice Adds new vault for `poolId`, `trancheId` and `asset`.
    function addVault(uint64 poolId, bytes16 trancheId, address vault, address asset, uint128 assetId) external;

    /// @notice Removes `vault` from `who`'s authorized callers
    function removeVault(uint64 poolId, bytes16 trancheId, address vault, address asset, uint128 assetId) external;

    /// @notice Returns the address of the vault for a given pool, tranche and asset
    function vaultByAssetId(uint64 poolId, bytes16 trancheId, uint128 assetId)
        external
        view
        returns (address vaultAddr);

    /// @notice Checks whether the vault is partially (a)synchronous and if so returns the address of the secondary
    /// manager.
    ///
    /// @param vaultAddr The address of vault that is checked
    /// @return vaultKind_ The kind of the vault
    /// @return secondaryManager The address of the secondary manager if the vault is partially (a)synchronous, else
    /// points to zero address
    function vaultKind(address vaultAddr) external view returns (VaultKind vaultKind_, address secondaryManager);
}
