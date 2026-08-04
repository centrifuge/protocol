// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";

/// @notice A pool's policy hook. Its enforcer calls {enforce} on every guarded call: the Hub on guarded
///         manager methods, the Spoke on guarded spoke calls. The policy itself holds no authorization
///         state. The ledger that stores, matures, vetoes and consumes authorizations lives in the enforcer's
///         registry ({IHubRegistry} on the Hub, {ISpokeRegistry} on the Spoke), so every policy shares one
///         audited, observable ledger.
/// @dev    How a call is classified is role-specific and lives in the subtypes: the Hub prices a delay
///         ({IHubPolicy}), the Spoke answers yes/no ({ISpokePolicy}). Zero and `false` both mean "in
///         policy". The two are intentionally distinct method names, so their selectors and interface ids
///         differ and neither can be read through the other's ABI; do not collapse them.
interface IPolicy {
    /// @notice Dispatched when {enforce} is called by anyone other than the enforcer (the Hub or Spoke this
    ///         policy is installed on).
    error NotEnforcer();

    /// @notice Enforce the pool's policy on a call. Callable only by the enforcer (the Hub or Spoke). No-op
    ///         when the call is in policy; otherwise consumes a matured authorization from the enforcer's
    ///         registry ledger, reverting if none exists.
    /// @param poolId The pool being operated on.
    /// @param caller The manager that initiated the call.
    /// @param data The call's calldata.
    function enforce(PoolId poolId, address caller, bytes calldata data) external;
}

/// @notice Hub-side policy. The Hub times a delay before an out-of-policy authorization can execute, so
///         classification returns that delay.
interface IHubPolicy is IPolicy {
    /// @notice Classify a call against the policy, returning the delay an authorization must age.
    /// @return delay 0 if the call is in policy (runs synchronously); otherwise the duration an
    ///         authorization for this call must age before it can execute. Reverts outright to block a
    ///         forbidden call (so it can't even be authorized).
    /// @param poolId The pool being operated on.
    /// @param caller The manager initiating the call.
    /// @param data The call's calldata.
    function authorizationDelay(PoolId poolId, address caller, bytes calldata data) external view returns (uint48 delay);
}

/// @notice Spoke-side policy. The Spoke has no local timelock — authorizations arrive already matured from the
///         Hub and are consumed from a counter ledger — so its policy decision is binary.
/// @dev    Unlike {IHubPolicy.authorizationDelay} (which the Hub calls to price the delay), the Spoke
///         enforcer never calls {authorizationRequired}: the in/out-of-policy decision lives inside {enforce}.
///         It is exposed purely for external consumers — off-chain tooling, monitoring, and UIs — to preview a
///         call's policy without sending it. It is therefore optional: a spoke policy need only implement
///         {IPolicy.enforce}, and implementing this interface is a convenience for exposing that preview in a
///         typed form.
interface ISpokePolicy is IPolicy {
    /// @notice Preview whether a call requires a matured authorization. Not called by the Spoke enforcer;
    ///         provided for off-chain and other external consumers.
    /// @return required true if the call requires a matured authorization consumed from the spoke ledger;
    ///         false if it runs synchronously (in policy). Reverts outright to block a forbidden call.
    /// @param poolId The pool being operated on.
    /// @param caller The manager initiating the call.
    /// @param data The call's calldata.
    function authorizationRequired(PoolId poolId, address caller, bytes calldata data)
        external
        view
        returns (bool required);
}
