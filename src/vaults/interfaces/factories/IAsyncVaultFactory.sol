// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IAsyncVaultFactory {
    /// @notice Deploys new vault for `poolId`, `scId` and `asset`.
    ///
    /// @param poolId Id of the pool. Id is one of the already supported pools.
    /// @param scId Id of the share class token. Id is one of the already supported share class tokens.
    /// @param asset Address of the underlying asset that's getting deposited inside the pool.
    /// @param token Address of the share class token that's getting issues against the deposited asset.
    /// @param escrow  A intermediary contract that holds a temporary funds until request is fulfilled.
    /// @param investmentManager Address of a contract that manages incoming/outgoing transactions.
    /// @param wards_   Address which can call methods behind authorized only.
    function newVault(
        uint64 poolId,
        bytes16 scId,
        address asset,
        address token,
        address escrow,
        address investmentManager,
        address[] calldata wards_
    ) external returns (address);
}
