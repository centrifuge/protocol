// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapterFailover} from "./interfaces/IAdapterFailover.sol";

import {Auth} from "../../misc/Auth.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IAdapter} from "../../core/messaging/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../../core/messaging/interfaces/IMultiAdapter.sol";
import {ITrustedContractUpdate} from "../../core/utils/interfaces/IContractUpdate.sol";

/// @title  AdapterFailover
/// @notice Optimistic, locally-executed failover of a pool's adapter set. See {IAdapterFailover}.
/// @dev    Must be registered as a manager of the local {MultiAdapter} for the relevant pools (via
///         `MultiAdapter.updateManager`) so `executeFailover` can install a set — it is not, and does
///         not need to be, a ward of MultiAdapter. Failover is driven by per-pool `steward`s (set by a
///         ward of this contract); only executing an armed failover is permissionless. The veto
///         (`trustedCall`) arrives over the pool's own adapters via the {ContractUpdater}, so it only
///         lands while those adapters still function — exactly when the takeover should be blocked.
contract AdapterFailover is Auth, ITrustedContractUpdate, IAdapterFailover {
    IMultiAdapter public immutable multiAdapter;
    address public immutable contractUpdater;

    uint64 public timelock;
    mapping(PoolId => mapping(address => bool)) public steward;
    mapping(uint16 centrifugeId => mapping(PoolId => Failover)) public pendingFailover;

    constructor(IMultiAdapter multiAdapter_, address contractUpdater_, uint64 timelock_, address deployer)
        Auth(deployer)
    {
        multiAdapter = multiAdapter_;
        contractUpdater = contractUpdater_;
        timelock = timelock_;
    }

    modifier onlySteward(PoolId poolId) {
        require(steward[poolId][msg.sender], NotSteward());
        _;
    }

    /// @dev The global pool (id 0) is the protocol's default set, managed by governance — never via failover.
    modifier notGlobalPool(PoolId poolId) {
        require(!poolId.isNull(), GlobalPoolNotAllowed());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapterFailover
    function file(bytes32 what, uint64 value) external auth {
        if (what == "timelock") timelock = value;
        else revert FileUnrecognizedParam();

        emit File(what, value);
    }

    /// @inheritdoc IAdapterFailover
    function updateSteward(PoolId poolId, address who, bool isSteward) external auth notGlobalPool(poolId) {
        _updateSteward(poolId, who, isSteward);
    }

    function _updateSteward(PoolId poolId, address who, bool isSteward) internal {
        steward[poolId][who] = isSteward;
        emit UpdateSteward(poolId, who, isSteward);
    }

    //----------------------------------------------------------------------------------------------
    // Failover lifecycle
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapterFailover
    function initiateFailover(
        uint16 centrifugeId,
        PoolId poolId,
        IAdapter[] calldata adapters,
        uint8 threshold,
        uint8 recoveryIndex
    ) external notGlobalPool(poolId) onlySteward(poolId) {
        // A new set must require at least one confirmation; threshold 0 would execute on any single delivery.
        require(threshold >= 1, InvalidThreshold());

        uint64 executableAt = uint64(block.timestamp) + timelock;
        pendingFailover[centrifugeId][poolId] =
            Failover(executableAt, keccak256(abi.encode(adapters, threshold, recoveryIndex)));

        emit InitiateFailover(centrifugeId, poolId, adapters, threshold, recoveryIndex, executableAt);
    }

    /// @inheritdoc IAdapterFailover
    function cancelFailover(uint16 centrifugeId, PoolId poolId) external notGlobalPool(poolId) onlySteward(poolId) {
        _cancel(centrifugeId, poolId);
    }

    /// @inheritdoc IAdapterFailover
    function blockSession(uint16 centrifugeId, PoolId poolId, uint16 sessionId)
        external
        notGlobalPool(poolId)
        onlySteward(poolId)
    {
        multiAdapter.blockSession(centrifugeId, poolId, sessionId);
    }

    /// @inheritdoc IAdapterFailover
    function executeFailover(
        uint16 centrifugeId,
        PoolId poolId,
        IAdapter[] calldata adapters,
        uint8 threshold,
        uint8 recoveryIndex
    ) external {
        Failover memory pending = pendingFailover[centrifugeId][poolId];
        require(pending.executableAt != 0, NoPendingFailover());
        require(block.timestamp >= pending.executableAt, TimelockNotElapsed());
        // A matured failover is executable for one timelock window, then expires and must be re-armed, so a
        // stale pending entry can't linger indefinitely. Uses the current timelock (negligible if it changed).
        require(block.timestamp <= pending.executableAt + timelock, FailoverExpired());
        require(keccak256(abi.encode(adapters, threshold, recoveryIndex)) == pending.paramsHash, ParamsMismatch());

        delete pendingFailover[centrifugeId][poolId];

        multiAdapter.setAdapters(centrifugeId, poolId, adapters, threshold, recoveryIndex);

        emit ExecuteFailover(centrifugeId, poolId, adapters, threshold, recoveryIndex);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming (veto)
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ITrustedContractUpdate
    /// @dev The hub reaches this contract over the pool's adapters, so these calls only land while those
    ///      adapters still function. `CancelFailover` vetoes a pending failover; `UpdateSteward` (re)assigns
    ///      who may drive failover for the pool. `payload` is the abi-encoded args prefixed with the
    ///      `TrustedCall` kind.
    function trustedCall(PoolId poolId, ShareClassId, bytes calldata payload) external notGlobalPool(poolId) {
        require(msg.sender == contractUpdater, NotContractUpdater());

        uint8 kindValue = abi.decode(payload, (uint8));
        require(kindValue <= uint8(type(TrustedCall).max), UnknownTrustedCall());

        TrustedCall kind = TrustedCall(kindValue);
        if (kind == TrustedCall.CancelFailover) {
            (, uint16 centrifugeId) = abi.decode(payload, (uint8, uint16));
            _cancel(centrifugeId, poolId);
        } else if (kind == TrustedCall.UpdateSteward) {
            (, address who, bool isSteward) = abi.decode(payload, (uint8, address, bool));
            _updateSteward(poolId, who, isSteward);
        }
    }

    function _cancel(uint16 centrifugeId, PoolId poolId) internal {
        delete pendingFailover[centrifugeId][poolId];
        emit BlockFailover(centrifugeId, poolId);
    }
}
