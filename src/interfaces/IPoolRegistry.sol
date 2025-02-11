// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";

interface IPoolRegistry {
    event NewPool(
        PoolId poolId, address indexed admin, IShareClassManager indexed shareClassManager, AssetId indexed currency
    );
    event UpdatedAdmin(PoolId indexed poolId, address indexed admin, bool canManage);
    event AllowedInvestorAsset(PoolId indexed poolId, AssetId indexed assetId, bool isAllowed);
    event SetMetadata(PoolId indexed poolId, bytes metadata);
    event UpdatedShareClassManager(PoolId indexed poolId, IShareClassManager indexed shareClassManager);
    event UpdatedCurrency(PoolId indexed poolId, AssetId currency);
    event SetAddressFor(PoolId indexed poolId, bytes32 key, address addr);

    error NonExistingPool(PoolId id);
    error EmptyAdmin();
    error EmptyAsset();
    error EmptyCurrency();
    error EmptyShareClassManager();

    /// @notice Register a new pool.
    /// @return a PoolId to identify the new pool.
    function registerPool(address admin, AssetId currency, IShareClassManager shareClassManager)
        external
        returns (PoolId);

    /// @notice allow/disallow an address as an admin for the pool
    function updateAdmin(PoolId poolId, address newAdmin, bool canManage) external;

    /// @notice allow/disallow an investor asset to be used in this pool
    function allowInvestorAsset(PoolId poolId, AssetId assetId, bool isAllowed) external;

    /// @notice sets metadata for this pool
    function setMetadata(PoolId poolId, bytes calldata metadata) external;

    /// @notice updates the share class manager of the pool
    function updateShareClassManager(PoolId poolId, IShareClassManager shareClassManager) external;

    /// @notice updates the currency of the pool
    function updateCurrency(PoolId poolId, AssetId currency) external;

    /// @notice sets an address for an specific key
    function setAddressFor(PoolId poolid, bytes32 key, address addr) external;

    /// @notice returns the metadata attached to the pool, if any.
    function metadata(PoolId poolId) external view returns (bytes memory);

    /// @notice returns the currency of the pool
    function currency(PoolId poolId) external view returns (AssetId);

    /// @notice returns the shareClassManager used in the pool
    function shareClassManager(PoolId poolId) external view returns (IShareClassManager);

    /// @notice returns the existance of an admin
    function isAdmin(PoolId poolId, address admin) external view returns (bool);

    /// @notice returns the allowance of an investor asset
    function isInvestorAssetAllowed(PoolId poolId, AssetId assetId) external view returns (bool);

    /// @notice returns the address for an specific key
    function addressFor(PoolId poolId, bytes32 key) external view returns (address);

    /// @notice checks the existence of a pool
    function exists(PoolId poolId) external view returns (bool);
}
