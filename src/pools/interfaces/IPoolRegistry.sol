// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";

interface IPoolRegistry {
    event NewPool(PoolId poolId, address indexed admin, AssetId indexed currency);
    event UpdateAdmin(PoolId indexed poolId, address indexed admin, bool canManage);
    event SetMetadata(PoolId indexed poolId, bytes metadata);
    event UpdateDependency(PoolId indexed poolId, bytes32 indexed what, address dependency);
    event UpdateCurrency(PoolId indexed poolId, AssetId currency);

    error NonExistingPool(PoolId id);
    error EmptyAdmin();
    error EmptyCurrency();
    error EmptyShareClassManager();

    /// @notice Register a new pool.
    /// @return a PoolId to identify the new pool.
    function registerPool(address admin, uint16 centrifugeId, AssetId currency) external returns (PoolId);

    /// @notice allow/disallow an address as an admin for the pool
    function updateAdmin(PoolId poolId, address newAdmin, bool canManage) external;

    /// @notice sets metadata for this pool
    function setMetadata(PoolId poolId, bytes calldata metadata) external;

    /// @notice updates a dependency of the pool
    function updateDependency(PoolId poolId, bytes32 what, address dependency) external;

    /// @notice updates the currency of the pool
    function updateCurrency(PoolId poolId, AssetId currency) external;

    /// @notice returns the metadata attached to the pool, if any.
    function metadata(PoolId poolId) external view returns (bytes memory);

    /// @notice returns the currency of the pool
    function currency(PoolId poolId) external view returns (AssetId);

    /// @notice returns the dependency used in the pool
    function dependency(PoolId poolId, bytes32 what) external view returns (address);

    /// @notice returns the existance of an admin
    function isAdmin(PoolId poolId, address admin) external view returns (bool);

    /// @notice checks the existence of a pool
    function exists(PoolId poolId) external view returns (bool);
}
