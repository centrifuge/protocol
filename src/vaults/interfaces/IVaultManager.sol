// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IBaseVault {
    /// @notice Returns the address of the manager contract handling the vault.
    function manager() external view returns (address);

    /// @notice Returns the address of asset that the vault is accepting
    function asset() external view returns (address);
}

interface IVaultManager {
    /// @notice Adds new vault for `poolId`, `trancheId` and `asset`.
    function addVault(uint64 poolId, bytes16 trancheId, address vault, address asset, uint128 assetId) external;

    /// @notice Removes `vault` from `who`'s authroized callers
    function removeVault(uint64 poolId, bytes16 trancheId, address vault, address asset, uint128 assetId) external;
}
