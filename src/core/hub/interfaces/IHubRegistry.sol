// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IBridgingHook} from "./IBridgingHook.sol";
import {IHubRequestManager} from "./IHubRequestManager.sol";

import {IERC6909Decimals} from "../../../misc/interfaces/IERC6909.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {IHubPolicy} from "../../utils/interfaces/IPolicy.sol";

interface IHubRegistry is IERC6909Decimals {
    //----------------------------------------------------------------------------------------------
    // Structs
    //----------------------------------------------------------------------------------------------

    /// @notice Registration state and decimals of a registered asset.
    struct AssetInfo {
        bool registered;
        uint8 decimals;
    }

    /// @dev Packed into one slot so authorization-id computation reads the policy and its install
    ///      nonce with a single SLOAD.
    struct PolicyInfo {
        IHubPolicy policy;
        uint64 nonce;
    }

    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event NewAsset(AssetId indexed assetId, uint8 decimals);
    event NewPool(PoolId indexed poolId, address indexed manager, AssetId indexed currency);
    event UpdateManager(PoolId indexed poolId, address indexed manager, bool canManage);
    event SetMetadata(PoolId indexed poolId, bytes metadata);
    event UpdateCurrency(PoolId indexed poolId, AssetId currency);
    event SetHubRequestManager(PoolId indexed poolId, uint16 indexed centrifugeId, IHubRequestManager manager);
    event SetBridgingHook(PoolId indexed poolId, address hook);
    event SetPolicy(PoolId indexed poolId, IHubPolicy policy);

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

    error NonExistingPool();
    error InvalidPool();
    error AssetAlreadyRegistered();
    error PoolAlreadyRegistered();
    error EmptyAccount();
    error EmptyCurrency();
    error EmptyShareClassManager();
    error AssetNotFound();
    /// @notice Dispatched when {registerAsset} targets the null AssetId, which is the "no currency"
    ///         sentinel: registering it would make decimal lookups succeed for non-existent pools.
    error EmptyAssetId();
    /// @notice Dispatched when {registerAsset} declares more than 18 decimals, the bound PricingLib
    ///         conversions assume (mirrors the spoke-side check in Spoke.registerAsset).
    error TooManyDecimals();
    /// @notice Dispatched when {updateCurrency} targets a currency whose decimals differ from the pool's current
    ///         currency; pool decimals must stay fixed to match already-deployed share tokens.
    error CurrencyDecimalsMismatch();
    /// @notice Dispatched when {initiateAuthorization} targets a pool with no policy installed (nothing to classify).
    error PolicyNotInstalled();
    /// @notice Dispatched when {initiateAuthorization} targets a call that is currently in policy (nothing to authorize).
    error InPolicy();
    /// @notice Dispatched when {initiateAuthorization} targets a call that already has an authorization (cancel first).
    error AlreadyAuthorized();
    /// @notice Dispatched when {consumeAuthorization} finds no matured, unexpired authorization, or when
    ///         {cancelAuthorization} finds no authorization to cancel.
    error Unauthorized();
    /// @notice Dispatched when {consumeAuthorization} is called by anyone other than the pool's policy.
    error CallerNotPolicy();

    //----------------------------------------------------------------------------------------------
    // Registration methods
    //----------------------------------------------------------------------------------------------

    /// @notice Register a new asset
    /// @param assetId The asset identifier; must not be the null AssetId
    /// @param decimals_ The number of decimals for the asset, at most 18
    function registerAsset(AssetId assetId, uint8 decimals_) external;

    /// @notice Register a new pool
    /// @param poolId The pool identifier
    /// @param manager The initial manager address for the pool
    /// @param currency The currency asset for the pool; must already be registered
    function registerPool(PoolId poolId, address manager, AssetId currency) external;

    //----------------------------------------------------------------------------------------------
    // Update methods
    //----------------------------------------------------------------------------------------------

    /// @notice Allow/disallow an address as a manager for the pool
    /// @param poolId The pool identifier
    /// @param who The address to update manager status for
    /// @param canManage Whether the address can manage the pool
    function updateManager(PoolId poolId, address who, bool canManage) external;

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

    /// @notice Updates the currency of the pool
    /// @param poolId The pool identifier
    /// @param currency The new currency asset
    function updateCurrency(PoolId poolId, AssetId currency) external;

    /// @notice Install or replace the policy for a pool
    /// @dev    Auth-gated: written through by the Hub, which enforces the policy on the change itself
    /// @param poolId The pool identifier
    /// @param policy The policy contract (address(0) to clear)
    function setPolicy(PoolId poolId, IHubPolicy policy) external;

    //----------------------------------------------------------------------------------------------
    // Authorization ledger
    //----------------------------------------------------------------------------------------------

    /// @notice Pre-authorize a future, out-of-policy Hub call. Callable only by the Hub (the manager check
    ///         lives in {IHub.initiateAuthorization}). The pool's policy classifies the call, using `caller` as the
    ///         authorizing manager; an in-policy call can't be authorized. Matures after the classified
    ///         delay, after which a guarded Hub call whose calldata byte-matches `data` consumes it.
    /// @param poolId The pool the call targets
    /// @param caller The manager authorizing the call (for classification and the audit event)
    /// @param data The exact future Hub calldata being authorized
    function initiateAuthorization(PoolId poolId, address caller, bytes calldata data) external;

    /// @notice Cancel a pending authorization. Callable only by the Hub (the manager check lives in
    ///         {IHub.cancelAuthorization}; sentinels act through their Supervisor, itself a registered
    ///         Hub manager).
    /// @param poolId The pool the authorization targets
    /// @param caller The manager cancelling the authorization (for the audit event)
    /// @param data The exact Hub calldata that was authorized
    function cancelAuthorization(PoolId poolId, address caller, bytes calldata data) external;

    /// @notice Consume a matured authorization for an executing out-of-policy call. Callable only by the
    ///         pool's installed policy (from its {IPolicy.enforce}). Reverts unless an authorization
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
    ///         current policy and its install nonce, so any policy change (including re-installing
    ///         a previous policy address) invalidates all pending authorizations.
    function authId(PoolId poolId, bytes calldata data) external view returns (bytes32);

    /// @notice Incremented on every {setPolicy}. Part of the {authId} namespace, so re-installing a
    ///         previously used policy address cannot resurrect authorizations from its earlier tenure.
    /// @param poolId The pool identifier
    function policyNonce(PoolId poolId) external view returns (uint64);

    /// @notice Returns the metadata attached to the pool, if any
    /// @param poolId The pool identifier
    /// @return The metadata bytes
    function metadata(PoolId poolId) external view returns (bytes memory);

    /// @notice Returns the currency of the pool
    /// @param poolId The pool identifier
    /// @return The currency asset identifier
    function currency(PoolId poolId) external view returns (AssetId);

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

    /// @notice Returns the policy installed for a pool (address(0) if none)
    /// @param poolId The pool identifier
    /// @return The policy contract
    function policy(PoolId poolId) external view returns (IHubPolicy);

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

    /// @notice Returns the registration state and decimals of an asset
    /// @param assetId The asset identifier
    /// @return registered Whether the asset is registered
    /// @return decimals The number of decimals
    function asset(AssetId assetId) external view returns (bool registered, uint8 decimals);

    /// @notice Set or clear the bridging hook for a pool
    /// @param poolId The pool identifier
    /// @param hook The hook contract, or address(0) to clear
    function setBridgingHook(PoolId poolId, IBridgingHook hook) external;

    /// @notice Returns the bridging hook for a pool, or address(0) if none
    function bridgingHook(PoolId poolId) external view returns (IBridgingHook);
}
