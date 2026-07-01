// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IManifest} from "./IManifest.sol";
import {IBridgingHook} from "./IBridgingHook.sol";
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
    event SetBridgingHook(PoolId indexed poolId, address hook);
    event SetManifest(PoolId indexed poolId, IManifest manifest);

    /// @notice Emitted when an out-of-policy Hub call is authorized: this starts the policy timelock.
    ///         The authorization matures at `validAfter` and may then run, unless cancelled first. `data`
    ///         is the exact authorized calldata, included so the action is decodable straight from logs.
    event AuthorizationScheduled(
        PoolId indexed poolId, address indexed caller, bytes32 indexed authId, uint48 validAfter, bytes data
    );
    /// @notice Emitted when a pending authorization is cancelled (a manager, or a sentinel via its
    ///         Supervisor). `caller` is whoever cancelled it.
    event AuthorizationCanceled(PoolId indexed poolId, address indexed caller, bytes32 indexed authId);
    /// @notice Emitted when a matured authorization is consumed by an executing out-of-policy call.
    ///         `caller` is the manager whose Hub call consumed it.
    event AuthorizationConsumed(PoolId indexed poolId, address indexed caller, bytes32 indexed authId);

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
    /// @notice Dispatched when {authorize}/{cancelAuthorization} caller is not a pool manager.
    error NotManager();
    /// @notice Dispatched when {authorize} targets a pool with no manifest installed (nothing to classify).
    error NoManifest();
    /// @notice Dispatched when {authorize} targets a call that is currently in policy (nothing to authorize).
    error InPolicy();
    /// @notice Dispatched when {authorize} targets a call that already has an authorization (cancel first).
    error AlreadyAuthorized();
    /// @notice Dispatched when {consumeAuthorization} finds no matured, unexpired authorization, or when
    ///         {cancelAuthorization} finds no authorization to cancel.
    error Unauthorized();
    /// @notice Dispatched when {consumeAuthorization} is called by anyone other than the pool's manifest.
    error NotManifest();

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

    /// @notice Install or replace the policy manifest for a pool
    /// @dev    Auth-gated: written through by the Hub, which enforces the policy on the change itself
    /// @param poolId The pool identifier
    /// @param manifest The manifest contract (address(0) to clear)
    function setManifest(PoolId poolId, IManifest manifest) external;

    //----------------------------------------------------------------------------------------------
    // Authorization ledger
    //----------------------------------------------------------------------------------------------

    /// @notice Pre-authorize a future, out-of-policy Hub call. Manager only. The pool's manifest
    ///         classifies the call; an in-policy call can't be authorized. Matures after the classified
    ///         delay, after which a guarded Hub call whose calldata byte-matches `data` consumes it.
    /// @param poolId The pool the call targets
    /// @param data The exact future Hub calldata being authorized
    function authorize(PoolId poolId, bytes calldata data) external;

    /// @notice Cancel a pending authorization. Manager only (sentinels act through their Supervisor).
    /// @param poolId The pool the authorization targets
    /// @param data The exact Hub calldata that was authorized
    function cancelAuthorization(PoolId poolId, bytes calldata data) external;

    /// @notice Consume a matured authorization for an executing out-of-policy call. Callable only by the
    ///         pool's installed manifest (from its {IManifest.enforce}). Reverts unless an authorization
    ///         exists, has matured, and is still within `expiry` of maturing.
    /// @param poolId The pool the call targets
    /// @param caller The manager whose Hub call is executing (for the audit event)
    /// @param data The exact Hub calldata being executed
    /// @param expiry The window, after maturing, in which the authorization stays executable
    function consumeAuthorization(PoolId poolId, address caller, bytes calldata data, uint48 expiry) external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice The timestamp at which a pending authorization matures (0 if none).
    /// @param authId The authorization identifier, see {authId}
    function authorizedAfter(bytes32 authId) external view returns (uint48 validAfter);

    /// @notice The identifier of an authorization for `data` on `poolId`, namespaced by the pool's
    ///         current manifest so swapping the manifest invalidates all of its pending authorizations.
    function authId(PoolId poolId, bytes calldata data) external view returns (bytes32);

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

    /// @notice Returns the policy manifest installed for a pool (address(0) if none)
    /// @param poolId The pool identifier
    /// @return The manifest contract
    function manifest(PoolId poolId) external view returns (IManifest);

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

    /// @notice Set or clear the bridging hook for a pool
    /// @param poolId The pool identifier
    /// @param hook The hook contract, or address(0) to clear
    function setBridgingHook(PoolId poolId, IBridgingHook hook) external;

    /// @notice Returns the bridging hook for a pool, or address(0) if none
    function bridgingHook(PoolId poolId) external view returns (IBridgingHook);
}
