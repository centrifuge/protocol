// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {Currency} from "src/types/Currency.sol";

interface IPoolRegistry {
    /// Events
    event NewPool(PoolId poolId, address indexed manager, address indexed shareClassManager, Currency indexed currency);
    event UpdatedPoolAdmin(PoolId indexed poolId, address indexed manager);
    event UpdatedPoolMetadata(PoolId indexed poolId, bytes metadata);
    event UpdatedShareClassManager(PoolId indexed poolId, address indexed shareClassManager);
    event UpdatedPoolCurrency(PoolId indexed poolId, Currency currency);

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
    /// @notice TODO
    function updateCurrency(PoolId poolId, Currency currency) external;
}
