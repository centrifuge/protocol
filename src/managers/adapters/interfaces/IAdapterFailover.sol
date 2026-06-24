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
///         veto it with a single trusted call routed over those same pool adapters (`trustedCall`). If
///         the pool adapters are genuinely dead the veto cannot land, the timelock elapses, and anyone
///         may `executeFailover` to install the new set locally. Working adapters block the takeover;
///         dead adapters cannot, so the failover only ever wins when it is actually needed.
interface IAdapterFailover {
    /// @notice Operations the hub can trigger over the pool's adapters via a trusted contract update.
    enum TrustedCall {
        CancelFailover,
        UpdateSteward
    }

    struct Failover {
        /// @notice Timestamp at which the failover may be executed. Zero means no failover is pending.
        uint64 executableAt;
        /// @notice keccak256(abi.encode(adapters, threshold, recoveryIndex)) of the proposed set. The
        ///         executor must reproduce the exact set, so only the armed configuration can be installed.
        bytes32 paramsHash;
    }

    event File(bytes32 indexed what, uint64 value);
    event UpdateSteward(PoolId indexed poolId, address indexed who, bool isSteward);
    event InitiateFailover(
        uint16 indexed centrifugeId,
        PoolId indexed poolId,
        IAdapter[] adapters,
        uint8 threshold,
        uint8 recoveryIndex,
        uint64 executableAt
    );
    event BlockFailover(uint16 indexed centrifugeId, PoolId indexed poolId);
    event ExecuteFailover(
        uint16 indexed centrifugeId, PoolId indexed poolId, IAdapter[] adapters, uint8 threshold, uint8 recoveryIndex
    );

    error FileUnrecognizedParam();
    error NotSteward();
    error GlobalPoolNotAllowed();
    error InvalidThreshold();
    error NotContractUpdater();
    error UnknownTrustedCall();
    error NoPendingFailover();
    error TimelockNotElapsed();
    error FailoverExpired();
    error ParamsMismatch();

    /// @notice Configure the contract. Currently only the "timelock" key (the veto window, in seconds).
    function file(bytes32 what, uint64 value) external;

    /// @notice Grant or revoke an account's permission to drive failover for a pool (arm, cancel, deny a
    ///         session). Ward-gated. The hub can also set a pool's steward over the pool's adapters via a
    ///         `TrustedCall.UpdateSteward` contract update. Executing an armed failover stays permissionless.
    function updateSteward(PoolId poolId, address who, bool isSteward) external;

    /// @notice Arm a failover of the (centrifugeId, poolId) adapter set. Starts the veto window; the set
    ///         can be installed by `executeFailover` once it elapses, unless vetoed first.
    function initiateFailover(
        uint16 centrifugeId,
        PoolId poolId,
        IAdapter[] calldata adapters,
        uint8 threshold,
        uint8 recoveryIndex
    ) external;

    /// @notice Cancel a pending failover locally (steward path, e.g. it was armed in error).
    function cancelFailover(uint16 centrifugeId, PoolId poolId) external;

    /// @notice Disable an adapter session on the local MultiAdapter. AdapterFailover is the registered
    ///         manager, so this is the steward's path to deny a stuck or compromised session.
    function denySession(uint16 centrifugeId, PoolId poolId, uint16 sessionId) external;

    /// @notice Install the armed set after the veto window has elapsed. Permissionless: the params must
    ///         match what was armed, so a finalizer cannot substitute a different set.
    function executeFailover(
        uint16 centrifugeId,
        PoolId poolId,
        IAdapter[] calldata adapters,
        uint8 threshold,
        uint8 recoveryIndex
    ) external;
}
