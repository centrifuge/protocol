// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title  IVault Interface
/// @notice Interface for the vault contract, needed to link/unlink vaults correctly
/// @dev Must be implemented by all vaults
interface IBaseVault {
    /// @notice Returns the address of the manager contract handling the vault.
    /// @dev This naming MUST NOT change due to requirements of olds vaults from v2
    /// @return The address of the manager contract that is between vault and gateway
    function manager() external view returns (address);

    /// @notice Returns the address of asset that the vault is accepting
    /// @dev This naming MUST NOT change due to requirements of olds vaults from v2
    /// @return The address of the asset that the vault is accepting
    function asset() external view returns (address);
}

/// @title  IVaultManager Interface
/// @notice Interface for the vault manager contract, needed to link/unlink vaults correctly.
/// @dev Must be implemented by all vault managers
interface IVaultManager {
    /// @notice Adds new vault for `poolId`, `trancheId` and `asset`.
    function addVault(uint64 poolId, bytes16 trancheId, address vault, address asset, uint128 assetId) external;

    /// @notice Removes `vault` from `who`'s authorized callers
    function removeVault(uint64 poolId, bytes16 trancheId, address vault, address asset, uint128 assetId) external;
}
