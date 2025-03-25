// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title  IVaultManager Interface
/// @notice Interface for the vault manager contract, needed to link/unlink vaults correctly.
/// @dev Must be implemented by all vault managers
interface IVaultManager {
    /// @notice Adds new vault for `poolId`, `trancheId` and `asset`.
    function addVault(uint64 poolId, bytes16 trancheId, address vault, address asset, uint128 assetId) external;

    /// @notice Removes `vault` from `who`'s authorized callers
    function removeVault(uint64 poolId, bytes16 trancheId, address vault, address asset, uint128 assetId) external;
}
