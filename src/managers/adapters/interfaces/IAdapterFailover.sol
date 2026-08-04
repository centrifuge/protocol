// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {IAdapter} from "../../../core/messaging/interfaces/IAdapter.sol";

/// @notice Optimistic, locally-executed failover of a pool's adapter set.
///
///         Pool adapter updates normally travel over the pool's own adapters (see MultiAdapter routing).
///         That removes the global set as a liveness dependency, but it cannot help a pool whose own
///         adapters have gone dark: the hub can no longer reach it to install a new set. AdapterFailover
///         is the backstop for that case.
///
///         A pool steward arms a failover with `initiateFailover`, which records the proposed set behind a
///         long timelock. While the timelock runs, the hub — if the pool's adapters still function — can
///         veto it via `fromHub` (the ManagerCall path). If the pool adapters are genuinely dead the veto
///         cannot land, the timelock elapses, and anyone may `executeFailover` to install the new set
///         locally. Working adapters block the takeover; dead adapters cannot, so the failover only ever
///         wins when it is actually needed.
///
///         The hub's veto (`CancelFailover` via `fromHub`) is dispatched through `Hub.managerCall`, which
///         is policy-classified like any other target not pinned in `StdHubPolicy._checkManagerCall` —
///         i.e. it is itself `delay`-gated, not instant. For the veto to be exercisable at all, the
///         timelock here must be configured with enough margin over the policy's `delay` (plus
///         dispatch/relay time) that a hub-initiated cancel can mature and execute before a malicious
///         `initiateFailover` reaches `executableAt`.
interface IAdapterFailover {
    /// @notice Operations the hub can trigger via the ManagerCall/Envoy path.
    enum HubCall {
        CancelFailover,
        UpdateSteward
    }

    struct Failover {
        /// @notice Timestamp at which the failover may be executed. Zero means no failover is pending.
        uint64 executableAt;
        /// @notice keccak256(abi.encode(adapters, threshold)) of the proposed set. The executor must
        ///         reproduce the exact set, so only the armed configuration can be installed.
        bytes32 paramsHash;
    }

    event UpdateSteward(PoolId indexed poolId, address indexed who, bool isSteward);
    event InitiateFailover(
        uint16 indexed centrifugeId, PoolId indexed poolId, IAdapter[] adapters, uint8 threshold, uint64 executableAt
    );
    event BlockFailover(uint16 indexed centrifugeId, PoolId indexed poolId);
    event ExecuteFailover(uint16 indexed centrifugeId, PoolId indexed poolId, IAdapter[] adapters, uint8 threshold);

    error NotSteward();
    error InvalidThreshold();
    error NotEnvoy();
    error UnexpectedValue();
    error NoPendingFailover();
    error TimelockNotElapsed();
    error FailoverExpired();
    error ParamsMismatch();

    /// @notice Arm a failover of the (centrifugeId, poolId) adapter set. Starts the veto window; the set
    ///         can be installed by `executeFailover` once it elapses, unless vetoed first.
    /// @dev    PoolId 0 (the global/default set) can never reach here: stewards are assigned only through
    ///         `fromHub` which is pool-manager-gated on the hub side, and the hub enforces valid pool IDs.
    function initiateFailover(uint16 centrifugeId, PoolId poolId, IAdapter[] calldata adapters, uint8 threshold)
        external;

    /// @notice Cancel a pending failover locally (steward path, e.g. it was armed in error).
    function cancelFailover(uint16 centrifugeId, PoolId poolId) external;

    /// @notice Install the armed set after the veto window has elapsed. Permissionless: the params must
    ///         match what was armed, so a finalizer cannot substitute a different set.
    function executeFailover(uint16 centrifugeId, PoolId poolId, IAdapter[] calldata adapters, uint8 threshold) external;
}
