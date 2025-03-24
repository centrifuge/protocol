// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/pools/types/PoolId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";

interface IPoolRegistry {
    event NewPool(
        PoolId poolId, address indexed admin, IShareClassManager indexed shareClassManager, AssetId indexed currency
    );
    event UpdatedAdmin(PoolId indexed poolId, address indexed admin, bool canManage);
    event SetMetadata(PoolId indexed poolId, bytes metadata);
    event UpdatedShareClassManager(PoolId indexed poolId, IShareClassManager indexed shareClassManager);
    event UpdatedCurrency(PoolId indexed poolId, AssetId currency);

    error NonExistingPool(PoolId id);
    error EmptyAdmin();
    error EmptyCurrency();
    error EmptyShareClassManager();

    /// @notice Register a new pool.
    /// @return a PoolId to identify the new pool.
    function registerPool(
        address admin,
        uint16 centrifugeChainId,
        AssetId currency,
        IShareClassManager shareClassManager
    ) external returns (PoolId);

    /// @notice allow/disallow an address as an admin for the pool
    function updateAdmin(PoolId poolId, address newAdmin, bool canManage) external;

    /// @notice sets metadata for this pool
    function setMetadata(PoolId poolId, bytes calldata metadata) external;

    /// @notice updates the share class manager of the pool
    function updateShareClassManager(PoolId poolId, IShareClassManager shareClassManager) external;

    /// @notice updates the currency of the pool
    function updateCurrency(PoolId poolId, AssetId currency) external;

    /// @notice returns the metadata attached to the pool, if any.
    function metadata(PoolId poolId) external view returns (bytes memory);

    /// @notice returns the currency of the pool
    function currency(PoolId poolId) external view returns (AssetId);

    /// @notice returns the shareClassManager used in the pool
    function shareClassManager(PoolId poolId) external view returns (IShareClassManager);

    /// @notice returns the existance of an admin
    function isAdmin(PoolId poolId, address admin) external view returns (bool);

    /// @notice checks the existence of a pool
    function exists(PoolId poolId) external view returns (bool);
}
