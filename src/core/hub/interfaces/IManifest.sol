// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";

/// @notice A pool's policy: a pure classifier its enforcer runs on every guarded call. The same interface
///         serves both sides — the Hub enforces it on guarded manager methods, and the Spoke enforces it on
///         guarded spoke calls. The manifest only decides *whether* a call is in policy and, if not, how long
///         an authorization must age. The authorization ledger itself (storing, maturing, vetoing and
///         consuming authorizations) lives in the enforcer's registry ({IHubRegistry} on the Hub,
///         {ISpokeRegistry} on the Spoke), so the policy and the timelock state are cleanly separated and
///         every manifest shares one audited, observable ledger.
interface IManifest {
    /// @notice Dispatched when {enforce} is called by anyone other than the enforcer (the Hub or Spoke this
    ///         manifest is installed on).
    error NotHub();

    /// @notice Classify a call against the policy.
    /// @return delay 0 if the call is in policy (runs synchronously); otherwise the duration an
    ///         authorization for this call must age before it can execute. Reverts outright to block a
    ///         forbidden call (so it can't even be authorized).
    /// @param poolId The pool being operated on.
    /// @param caller The manager initiating the call.
    /// @param data The call's calldata.
    function classify(PoolId poolId, address caller, bytes calldata data) external view returns (uint48 delay);

    /// @notice Classify and enforce a call. Callable only by the enforcer (the Hub or Spoke). No-op when the
    ///         call is in policy; otherwise consumes a matured authorization from the enforcer's registry
    ///         ledger, reverting if none exists.
    /// @param poolId The pool being operated on.
    /// @param caller The manager that initiated the call.
    /// @param data The call's calldata.
    function enforce(PoolId poolId, address caller, bytes calldata data) external;
}
