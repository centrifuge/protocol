// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapterFailover} from "./interfaces/IAdapterFailover.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {IAdapter} from "../../core/messaging/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../../core/messaging/interfaces/IMultiAdapter.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";

/// @title  AdapterFailover
/// @notice This contract allows a per-pool steward to propose a new adapter set behind a timelock,
///         which anyone can execute once it elapses. It is intended as a recovery mechanism for pools
///         whose adapters have gone dark and can no longer be reached via the standard adapter set
///         message. The hub can veto the proposal over the pool's existing adapters while they still
///         function, preventing unauthorized takeovers.
contract AdapterFailover is IManagerCallFromHub, IAdapterFailover {
    address public immutable envoy;
    IMultiAdapter public immutable multiAdapter;
    uint64 public immutable timelock;

    mapping(PoolId => mapping(address => bool)) public steward;
    mapping(uint16 centrifugeId => mapping(PoolId => Failover)) public pendingFailover;

    constructor(address envoy_, IMultiAdapter multiAdapter_, uint64 timelock_) {
        envoy = envoy_;
        multiAdapter = multiAdapter_;
        timelock = timelock_;
    }

    modifier onlySteward(PoolId poolId) {
        require(steward[poolId][msg.sender], NotSteward());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Hub actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManagerCallFromHub
    function fromHub(PoolId poolId, bytes calldata payload) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());

        HubCall kind = HubCall(abi.decode(payload, (uint8)));
        if (kind == HubCall.CancelFailover) {
            (, uint16 centrifugeId) = abi.decode(payload, (uint8, uint16));
            _cancel(centrifugeId, poolId);
        } else if (kind == HubCall.UpdateSteward) {
            (, address who, bool isSteward) = abi.decode(payload, (uint8, address, bool));
            steward[poolId][who] = isSteward;
            emit UpdateSteward(poolId, who, isSteward);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Failover lifecycle
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapterFailover
    function initiateFailover(uint16 centrifugeId, PoolId poolId, IAdapter[] calldata adapters, uint8 threshold)
        external
        onlySteward(poolId)
    {
        require(threshold >= 1, InvalidThreshold());

        uint64 executableAt = uint64(block.timestamp) + timelock;
        pendingFailover[centrifugeId][poolId] = Failover(executableAt, keccak256(abi.encode(adapters, threshold)));

        emit InitiateFailover(centrifugeId, poolId, adapters, threshold, executableAt);
    }

    /// @inheritdoc IAdapterFailover
    function cancelFailover(uint16 centrifugeId, PoolId poolId) external onlySteward(poolId) {
        _cancel(centrifugeId, poolId);
    }

    /// @inheritdoc IAdapterFailover
    function executeFailover(uint16 centrifugeId, PoolId poolId, IAdapter[] calldata adapters, uint8 threshold)
        external
    {
        Failover memory pending = pendingFailover[centrifugeId][poolId];
        require(pending.executableAt != 0, NoPendingFailover());
        require(block.timestamp >= pending.executableAt, TimelockNotElapsed());
        require(block.timestamp <= pending.executableAt + timelock, FailoverExpired());
        require(keccak256(abi.encode(adapters, threshold)) == pending.paramsHash, ParamsMismatch());
        delete pendingFailover[centrifugeId][poolId];

        uint16 targetSessionId = multiAdapter.nextActiveSessionId(centrifugeId, poolId);
        multiAdapter.setAdapters(centrifugeId, poolId, adapters, threshold, targetSessionId);

        emit ExecuteFailover(centrifugeId, poolId, adapters, threshold);
    }

    function _cancel(uint16 centrifugeId, PoolId poolId) internal {
        delete pendingFailover[centrifugeId][poolId];
        emit BlockFailover(centrifugeId, poolId);
    }
}
