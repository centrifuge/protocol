// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IPoolRegistry {
    /// Types
    type PoolId is uint64;
    type CurrencyId is address;

    /// Events
    event NewPool(PoolId indexed poolId, address indexed manager);
    event NewPoolManager(address indexed manager);
    event NewPoolMetadata(PoolId indexed poolId, bytes metadata);

    /// Errors
    error NotManagerOrNonExistingPool();

    /// @notice TODO
    function registerPool(CurrencyId poolCurrency, address shareClassManager) external payable returns (PoolId);
    /// @notice TODO
    function changeManager(PoolId poolId, address manager) external;
    /// @notice TODO
    function updateMetadata(PoolId poolId, bytes calldata metadata) external;
}
