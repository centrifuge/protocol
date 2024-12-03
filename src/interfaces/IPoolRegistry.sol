// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {Currency} from "src/types/Currency.sol";

interface IPoolRegistry {
    /// Events
    event NewPool(PoolId indexed poolId, address indexed manager, address indexed shareClassManager, Currency currency);
    event NewPoolManager(PoolId indexed poolId, address indexed manager);
    event NewPoolMetadata(PoolId indexed poolId, bytes metadata);
    event NewShareClassManager(PoolId indexed poolId, address indexed shareClassManager);

    /// Errors
    error NonExistingPool(PoolId id);
    error EmptyAdmin();
    error EmptyCurrency();
    error EmptyShareClassManager();

    /// @notice TODO
    function registerPool(address admin, Currency currency, address shareClassManager) external returns (PoolId);
    /// @notice TODO
    function updateAdmin(PoolId poolId, address newAdmin, bool canManage) external;
    /// @notice TODO
    function updateMetadata(PoolId poolId, bytes calldata metadata) external;
    /// @notice TODO
    function updateShareClassManager(PoolId poolId, address shareClassManager) external;
}
