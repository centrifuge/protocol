// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

interface IERC7540VaultFactory {
    /// @notice Deploys new vault for `poolId`, `trancheId` and `asset`.
    ///
    /// @param poolId Id of the pool. Id is one of the already supported pools.
    /// @param trancheId Id of the tranche. Id is one of the already supported tranches.
    /// @param asset Address of the underlying asset that's getting deposited inside the pool.
    /// @param tranche Address of the tranche token that's getting issues against the deposited asset.
    /// @param escrow  A intermediary contract that holdsa temporary funds until request is fulfilled.
    /// @param investmentManager Address of a contract that manages incoming/outgoing transactions.
    /// @param wards_   Address which can call methods behind authorized only.
    function newVault(
        uint64 poolId,
        bytes16 trancheId,
        address asset,
        address tranche,
        address escrow,
        address investmentManager,
        address[] calldata wards_
    ) external returns (address);

    /// @notice Removes `vault` from `who`'s authroized callers
    ///
    /// @param vault Address of the vault to be remove from the authorized callers list.
    /// @param investmentManager Address of the manager to remove the vault from.
    function denyVault(address vault, address investmentManager) external;
}
