// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IVaultFactory {
    /// @notice Deploys new vault for `poolId`, `trancheId` and `asset`.
    ///
    /// @param poolId Id of the pool. Id is one of the already supported pools.
    /// @param trancheId Id of the tranche. Id is one of the already supported tranches.
    /// @param asset Address of the underlying asset that is getting deposited inside the pool.
    /// @param asset Token id of the underlying asset that is getting deposited inside the pool. I.e. zero if asset
    /// corresponds to ERC20 or non-zero if asset corresponds to ERC6909.
    /// @param tranche Address of the tranche token that is getting issues against the deposited asset.
    /// @param escrow An intermediary contract that holds a temporary funds until request is fulfilled.
    /// @param wards_ Address which can call methods behind authorized only.
    function newVault(
        uint64 poolId,
        bytes16 trancheId,
        address asset,
        uint256 tokenId,
        address tranche,
        address escrow,
        address[] calldata wards_
    ) external returns (address);
}
