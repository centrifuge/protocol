// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {Currency} from "src/types/Currency.sol";

interface IPoolRegistry {
    /// Events
    event NewPool(PoolId indexed poolId, address indexed manager);
    event NewPoolManager(address indexed manager);
    event NewPoolMetadata(PoolId indexed poolId, bytes metadata);

    /// Errors
    error NotManagerOrNonExistingPool();

    /// @notice TODO
    function registerPool(Currency poolCurrency, address shareClassManager) external returns (PoolId);
    /// @notice TODO
    function changeManager(address currentManager, PoolId poolId, address newManager) external;
    /// @notice TODO
    function updateMetadata(address currentManager, PoolId poolId, bytes calldata metadata) external;
}
