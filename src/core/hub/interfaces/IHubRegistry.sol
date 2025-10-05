// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IHubRequestManager} from "./IHubRequestManager.sol";

import {IERC6909Decimals} from "../../../misc/interfaces/IERC6909.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";

interface IHubRegistry is IERC6909Decimals {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event NewAsset(AssetId indexed assetId, uint8 decimals);
    event NewPool(PoolId poolId, address indexed manager, AssetId indexed currency);
    event UpdateManager(PoolId indexed poolId, address indexed manager, bool canManage);
    event SetMetadata(PoolId indexed poolId, bytes metadata);
    event UpdateDependency(PoolId indexed poolId, bytes32 indexed what, address dependency);
    event UpdateCurrency(PoolId indexed poolId, AssetId currency);
    event SetHubRequestManager(PoolId indexed poolId, uint16 indexed centrifugeId, IHubRequestManager manager);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error NonExistingPool(PoolId id);
    error AssetAlreadyRegistered();
    error PoolAlreadyRegistered();
    error EmptyAccount();
    error EmptyCurrency();
    error EmptyShareClassManager();
    error AssetNotFound();

    //----------------------------------------------------------------------------------------------
    // Registration methods
    //----------------------------------------------------------------------------------------------

    /// @notice Register a new asset
    /// @param assetId The asset identifier
    /// @param decimals_ The number of decimals for the asset
    function registerAsset(AssetId assetId, uint8 decimals_) external;

    /// @notice Register a new pool
    /// @param poolId The pool identifier
    /// @param manager The initial manager address for the pool
    /// @param currency The currency asset for the pool
    function registerPool(PoolId poolId, address manager, AssetId currency) external;

    //----------------------------------------------------------------------------------------------
    // Update methods
    //----------------------------------------------------------------------------------------------

    /// @notice Allow/disallow an address as a manager for the pool
    /// @param poolId The pool identifier
    /// @param newManager The address to update manager status for
    /// @param canManage Whether the address can manage the pool
    function updateManager(PoolId poolId, address newManager, bool canManage) external;

    /// @notice Set the hub request manager for a pool on a specific network
    /// @param poolId The pool identifier
    /// @param centrifuge The network identifier
    /// @param manager The hub request manager contract
    function setHubRequestManager(PoolId poolId, uint16 centrifuge, IHubRequestManager manager) external;

    /// @notice Sets metadata for this pool
    /// @param poolId The pool identifier
    /// @param metadata The metadata to attach
    function setMetadata(PoolId poolId, bytes calldata metadata) external;

    /// @notice Updates a dependency of the system
    /// @param poolId The pool identifier
    /// @param what The dependency identifier
    /// @param dependency The dependency contract address
    function updateDependency(PoolId poolId, bytes32 what, address dependency) external;

    /// @notice Updates the currency of the pool
    /// @param poolId The pool identifier
    /// @param currency The new currency asset
    function updateCurrency(PoolId poolId, AssetId currency) external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the metadata attached to the pool, if any
    /// @param poolId The pool identifier
    /// @return The metadata bytes
    function metadata(PoolId poolId) external view returns (bytes memory);

    /// @notice Returns the currency of the pool
    /// @param poolId The pool identifier
    /// @return The currency asset identifier
    function currency(PoolId poolId) external view returns (AssetId);

    /// @notice Returns the dependency used in the system
    /// @param poolId The pool identifier
    /// @param what The dependency identifier
    /// @return The dependency contract address
    function dependency(PoolId poolId, bytes32 what) external view returns (address);

    /// @notice Returns whether the account is a manager
    /// @param poolId The pool identifier
    /// @param who The address to check
    /// @return Whether the address is a manager
    function manager(PoolId poolId, address who) external view returns (bool);

    /// @notice Returns the hub request manager for a pool and centrifuge ID
    /// @param poolId The pool identifier
    /// @param centrifugeId The network identifier
    /// @return The hub request manager contract
    function hubRequestManager(PoolId poolId, uint16 centrifugeId) external view returns (IHubRequestManager);

    /// @notice Compute a pool ID given an ID postfix
    /// @param centrifugeId The network identifier
    /// @param postfix The pool ID postfix
    /// @return poolId The computed pool identifier
    function poolId(uint16 centrifugeId, uint48 postfix) external view returns (PoolId poolId);

    /// @notice Returns the decimals for an asset
    /// @param assetId The asset identifier
    /// @return The number of decimals
    function decimals(AssetId assetId) external view returns (uint8);

    /// @notice Returns the decimals for a pool
    /// @param poolId The pool identifier
    /// @return The number of decimals
    function decimals(PoolId poolId) external view returns (uint8);

    /// @notice Checks the existence of a pool
    /// @param poolId The pool identifier
    /// @return Whether the pool exists
    function exists(PoolId poolId) external view returns (bool);

    /// @notice Checks the existence of an asset
    /// @param assetId The asset identifier
    /// @return Whether the asset is registered
    function isRegistered(AssetId assetId) external view returns (bool);
}
