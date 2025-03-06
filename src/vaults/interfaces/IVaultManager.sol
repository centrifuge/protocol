// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IBaseVault {
    function manager() external view returns (address);

    function asset() external view returns (address);
}

interface IVaultManager {

    /// @notice Deploys new vault for `poolId`, `trancheId` and `asset`.
    function addVault(uint64 poolId, bytes16 trancheId, address vault) external;

    /// @notice Removes `vault` from `who`'s authroized callers
    function removeVault(uint64 poolId, bytes16 trancheId, address vault) external;
}
