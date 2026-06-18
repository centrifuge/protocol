// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";

/// @notice A pool's policy and authorization registry. The Hub calls {enforce} on every guarded
///         manager method. The manifest classifies the call: in-policy calls run synchronously,
///         out-of-policy calls must have been pre-authorized via {authorize} and matured past the
///         policy delay (giving sentinels a window to {cancelAuthorization}). Matching is by exact
///         calldata for now; structured / interval matching is a planned upgrade.
interface IManifest {
    /// @notice Emitted when an out-of-policy Hub call is pre-authorized. The call may run once
    ///         `validAfter` is reached, unless cancelled first. The authorized calldata is
    ///         available in the {authorize} transaction's input data.
    event Authorized(PoolId indexed poolId, address indexed caller, bytes32 indexed authId, uint48 validAfter);
    /// @notice Emitted when a pending authorization is cancelled (e.g. vetoed by a sentinel).
    event AuthorizationCanceled(PoolId indexed poolId, bytes32 indexed authId);

    /// @notice Dispatched when {enforce} is called by anyone other than the Hub.
    error NotHub();
    /// @notice Dispatched when {authorize}/{cancelAuthorization} caller is not a pool manager.
    error NotManager();
    /// @notice Dispatched when an out-of-policy call has no matured authorization backing it.
    error Unauthorized();
    /// @notice Dispatched when {authorize} is called for a call that is currently in policy (nothing
    ///         to authorize; banking it could be replayed later when the same call is out of policy).
    error InPolicy();
    /// @notice Dispatched when {authorize} is called for a call that already has an authorization
    ///         (pending or expired). Re-authorizing would silently reset the maturity clock, so a
    ///         stale authorization must be cancelled via {cancelAuthorization} before re-authorizing.
    error AlreadyAuthorized();

    /// @notice The timestamp at which a pending authorization matures (0 if none).
    /// @param authId keccak256(abi.encodePacked(poolId.raw(), callData))
    function authorizedAfter(bytes32 authId) external view returns (uint48 validAfter);

    /// @notice Classify and enforce a Hub call against the policy. Hub only. No-op when the call
    ///         is in policy; otherwise requires (and consumes) a matured authorization, reverting
    ///         if none exists. Reverts outright to block a forbidden call.
    /// @param poolId The pool being operated on.
    /// @param caller The manager that initiated the Hub call.
    /// @param data The Hub call's calldata.
    function enforce(PoolId poolId, address caller, bytes calldata data) external;

    /// @notice Pre-authorize a future, out-of-policy Hub call. Manager only. The authorization
    ///         matures after the policy delay; once matured, a guarded Hub call whose calldata
    ///         byte-matches `data` executes and consumes it.
    /// @param poolId The pool the call targets.
    /// @param data The exact future Hub calldata being authorized.
    function authorize(PoolId poolId, bytes calldata data) external;

    /// @notice Cancel a pending authorization. Manager only (sentinels act through their Supervisor).
    /// @param poolId The pool the authorization targets.
    /// @param data The exact Hub calldata that was authorized.
    function cancelAuthorization(PoolId poolId, bytes calldata data) external;
}
