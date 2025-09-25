// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IHubRequestManager} from "./IHubRequestManager.sol";

import {IERC6909Decimals} from "../../misc/interfaces/IERC6909.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";

interface IHubRegistry is IERC6909Decimals {
    event NewAsset(AssetId indexed assetId, uint8 decimals);
    event NewPool(PoolId poolId, address indexed manager, AssetId indexed currency);
    event UpdateManager(PoolId indexed poolId, address indexed manager, bool canManage);
    event SetMetadata(PoolId indexed poolId, bytes metadata);
    event UpdateDependency(PoolId indexed poolId, bytes32 indexed what, address dependency);
    event UpdateCurrency(PoolId indexed poolId, AssetId currency);
    event SetHubRequestManager(PoolId indexed poolId, uint16 indexed centrifugeId, IHubRequestManager manager);

    error NonExistingPool(PoolId id);
    error AssetAlreadyRegistered();
    error PoolAlreadyRegistered();
    error EmptyAccount();
    error EmptyCurrency();
    error EmptyShareClassManager();
    error AssetNotFound();

    /// @notice Register a new asset.
    function registerAsset(AssetId assetId, uint8 decimals_) external;

    /// @notice Register a new pool.
    function registerPool(PoolId poolId, address manager, AssetId currency) external;

    /// @notice allow/disallow an address as a manager for the pool
    function updateManager(PoolId poolId, address newManager, bool canManage) external;

    /// @notice TODO
    function setHubRequestManager(PoolId poolId, uint16 centrifuge, IHubRequestManager manager) external;

    /// @notice sets metadata for this pool
    function setMetadata(PoolId poolId, bytes calldata metadata) external;

    /// @notice updates a dependency of the system
    function updateDependency(PoolId poolId, bytes32 what, address dependency) external;

    /// @notice updates the currency of the pool
    function updateCurrency(PoolId poolId, AssetId currency) external;

    /// @notice returns the metadata attached to the pool, if any.
    function metadata(PoolId poolId) external view returns (bytes memory);

    /// @notice returns the currency of the pool
    function currency(PoolId poolId) external view returns (AssetId);

    /// @notice returns the dependency used in the system
    function dependency(PoolId poolId, bytes32 what) external view returns (address);

    /// @notice returns whether the account is a manager
    function manager(PoolId poolId, address who) external view returns (bool);

    /// @notice returns the hub request manager for a pool and centrifuge ID
    function hubRequestManager(PoolId poolId, uint16 centrifugeId) external view returns (IHubRequestManager);

    /// @notice compute a pool ID given an ID postfix
    function poolId(uint16 centrifugeId, uint48 postfix) external view returns (PoolId poolId);

    /// @notice returns the decimals for an asset
    function decimals(AssetId assetId) external view returns (uint8);

    /// @notice returns the decimals for a pool
    function decimals(PoolId poolId) external view returns (uint8);

    /// @notice checks the existence of a pool
    function exists(PoolId poolId) external view returns (bool);

    /// @notice checks the existence of an asset
    function isRegistered(AssetId assetId) external view returns (bool);
}
