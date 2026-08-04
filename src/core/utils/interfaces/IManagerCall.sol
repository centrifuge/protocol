// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";

/// @notice Hub-direction target surface for the payable `ManagerCall` path. Pool-scoped: any `scId` is
///         encoded in `payload`. Targets are reached through the `Envoy` (never the Hub, which redeploys).
/// @dev    Intentionally distinct from {IManagerCallFromSpoke}: distinct method names = distinct selectors,
///         so `Envoy.callFromSpoke` reverts on any hub-only target that implements `fromHub` only — that
///         selector mismatch is the direction boundary; do not collapse the two interfaces. `payable` is
///         required for value forwarding. The signature is final: the `Envoy` holds it across releases and
///         must never redeploy. No origin `(centrifugeId, sender)`: the call is already authorized at the
///         Hub (`_enforce` + policy) and the origin is always the hub's own chain.
interface IManagerCallFromHub {
    /// @notice Triggers a policy-supervised manager action. Caller MUST be the `Envoy`.
    /// @dev    Authorization is enforced at `Hub.managerCall` -> `_enforce` -> policy before this runs.
    ///         Value (if any) funds downstream messages.
    /// @param  poolId The pool the call is scoped to
    /// @param  payload Action-specific encoding decoded by the target
    function fromHub(PoolId poolId, bytes calldata payload) external payable;
}

/// @notice Spoke-direction target surface for the payable `ManagerCall` path. Reached via the
///         `ManagerCallFromSpoke` message -> `Envoy.callFromSpoke`. Bypasses the Hub's policy check by
///         construction, so the target MUST validate `(centrifugeId, sender)`.
/// @dev    Implemented by e.g. `OracleValuation` for feeder-validated remote price updates.
///         Distinct from {IManagerCallFromHub} — that split is the direction boundary; do not collapse them.
interface IManagerCallFromSpoke {
    /// @notice Triggers a manager action on a spoke-direction target. Caller MUST be the `Envoy`.
    /// @dev    Untrusted: bypasses the pool's policy. The target MUST validate `(centrifugeId, sender)`.
    ///         Value (if any) funds downstream messages.
    /// @param  poolId The pool the call is scoped to
    /// @param  payload Action-specific encoding decoded by the target
    /// @param  centrifugeId Origin chain of the caller
    /// @param  sender The originating actor (the spoke-side caller)
    function fromSpoke(PoolId poolId, bytes calldata payload, uint16 centrifugeId, bytes32 sender) external payable;
}
