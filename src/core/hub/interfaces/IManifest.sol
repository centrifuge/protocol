// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";

/// @notice A pool's policy: a pure classifier the Hub enforces on every guarded manager method.
///         The manifest only decides *whether* a call is in policy and, if not, how long an
///         authorization must age. The authorization ledger itself (storing, maturing, vetoing and
///         consuming authorizations) lives in {IHubRegistry}, so the policy and the timelock state are
///         cleanly separated and every manifest shares one audited, observable ledger.
interface IManifest {
    /// @notice Dispatched when {enforce} is called by anyone other than the Hub.
    error NotHub();

    /// @notice Classify a Hub call against the policy.
    /// @return delay 0 if the call is in policy (runs synchronously); otherwise the duration an
    ///         authorization for this call must age before it can execute. Reverts outright to block a
    ///         forbidden call (so it can't even be authorized).
    /// @param poolId The pool being operated on.
    /// @param caller The manager initiating the call.
    /// @param data The Hub call's calldata.
    function classify(PoolId poolId, address caller, bytes calldata data) external view returns (uint48 delay);

    /// @notice Classify and enforce a Hub call. Hub only. No-op when the call is in policy; otherwise
    ///         consumes a matured authorization from the {IHubRegistry} ledger, reverting if none exists.
    /// @param poolId The pool being operated on.
    /// @param caller The manager that initiated the Hub call.
    /// @param data The Hub call's calldata.
    function enforce(PoolId poolId, address caller, bytes calldata data) external;
}
