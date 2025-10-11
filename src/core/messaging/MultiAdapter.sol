// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "./interfaces/IAdapter.sol";
import {IMessageHandler} from "./interfaces/IMessageHandler.sol";
import {IMessageProperties} from "./interfaces/IMessageProperties.sol";
import {IMultiAdapter, MAX_ADAPTER_COUNT} from "./interfaces/IMultiAdapter.sol";

import {Auth} from "../../misc/Auth.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {ArrayLib} from "../../misc/libraries/ArrayLib.sol";
import {BytesLib} from "../../misc/libraries/BytesLib.sol";

import {PoolId} from "../types/PoolId.sol";

/// @title  MultiAdapter
/// @notice This contract manages multiple cross-chain messaging adapters and implements a voting mechanism
///         to ensure message consensus, requiring a configurable threshold of adapter confirmations before
///         forwarding messages to the gateway for execution.
contract MultiAdapter is Auth, IMultiAdapter {
    using CastLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;
    using ArrayLib for int16[8];

    PoolId public constant GLOBAL_POOL = PoolId.wrap(0);

    uint16 public immutable localCentrifugeId;

    IMessageHandler public gateway;
    IMessageProperties public messageProperties;

    uint64 globalSessionId;

    mapping(uint16 centrifugeId => mapping(PoolId => IAdapter[])) public adapters;
    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => Inbound)) public inbound;
    mapping(uint16 centrifugeId => mapping(PoolId => mapping(IAdapter adapter => Adapter))) internal _adapterDetails;

    constructor(uint16 localCentrifugeId_, IMessageHandler gateway_, address deployer) Auth(deployer) {
        localCentrifugeId = localCentrifugeId_;
        gateway = gateway_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMultiAdapter
    function file(bytes32 what, address instance) external auth {
        if (what == "gateway") gateway = IMessageHandler(instance);
        else if (what == "messageProperties") messageProperties = IMessageProperties(instance);
        else revert FileUnrecognizedParam();

        emit File(what, instance);
    }

    /// @inheritdoc IMultiAdapter
    function setAdapters(
        uint16 centrifugeId,
        PoolId poolId,
        IAdapter[] calldata addresses,
        uint8 threshold_,
        uint8 recoveryIndex_
    ) external auth {
        uint8 quorum_ = addresses.length.toUint8();
        require(quorum_ != 0, EmptyAdapterSet());
        require(quorum_ <= MAX_ADAPTER_COUNT, ExceedsMax());
        require(threshold_ <= quorum_, ThresholdHigherThanQuorum());
        require(recoveryIndex_ <= quorum_, RecoveryIndexHigherThanQuorum());

        // Increment session id to reset pending votes
        uint256 numAdapters = adapters[centrifugeId][poolId].length;
        uint64 sessionId = numAdapters > 0
            ? _adapterDetails[centrifugeId][poolId][adapters[centrifugeId][poolId][0]].activeSessionId + 1
            : globalSessionId + 1;

        // Disable old adapters
        for (uint8 i; i < numAdapters; i++) {
            delete _adapterDetails[centrifugeId][poolId][adapters[centrifugeId][poolId][i]];
        }

        // Enable new adapters, setting quorum to number of adapters
        for (uint8 j; j < quorum_; j++) {
            require(_adapterDetails[centrifugeId][poolId][addresses[j]].id == 0, NoDuplicatesAllowed());

            // Ids are assigned sequentially starting at 1
            _adapterDetails[centrifugeId][poolId][addresses[j]] =
                Adapter(j + 1, quorum_, threshold_, recoveryIndex_, sessionId);
        }

        adapters[centrifugeId][poolId] = addresses;
        if (poolId == GLOBAL_POOL) globalSessionId = sessionId;

        emit SetAdapters(centrifugeId, poolId, addresses, threshold_, recoveryIndex_);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageHandler
    function handle(uint16 centrifugeId, bytes calldata payload) external {
        PoolId poolId = messageProperties.messagePoolId(payload);

        IAdapter adapterAddr = IAdapter(msg.sender);
        Adapter memory adapter = _poolAdapterDetails(centrifugeId, poolId, adapterAddr);
        require(adapter.id != 0, InvalidAdapter());

        // Verify adapter and parse message hash
        bytes32 payloadHash = keccak256(payload);
        bytes32 payloadId = keccak256(abi.encodePacked(centrifugeId, localCentrifugeId, payloadHash));
        emit HandlePayload(centrifugeId, payloadId, payload, adapterAddr);

        // Special case for gas efficiency
        if (adapter.quorum == 1) {
            gateway.handle(centrifugeId, payload);
            return;
        }

        Inbound storage state = inbound[centrifugeId][payloadHash];

        if (adapter.activeSessionId != state.sessionId) {
            // Clear votes from previous session
            delete state.votes;
            state.sessionId = adapter.activeSessionId;
        }

        // Increase vote
        state.votes[adapter.id - 1]++;

        if (state.votes.countPositiveValues(adapter.quorum) >= adapter.threshold) {
            // Reduce votes by quorum
            state.votes.decreaseFirstNValues(adapter.quorum, adapter.recoveryIndex);

            gateway.handle(centrifugeId, payload);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    function send(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit, address refund)
        external
        payable
        auth
        returns (bytes32)
    {
        PoolId poolId = messageProperties.messagePoolId(payload);
        IAdapter[] memory adapters_ = poolAdapters(centrifugeId, poolId);
        require(adapters_.length != 0, EmptyAdapterSet());

        bytes32 payloadId = keccak256(abi.encodePacked(localCentrifugeId, centrifugeId, keccak256(payload)));
        for (uint256 i = 0; i < adapters_.length; i++) {
            _sendToAdapter(centrifugeId, payloadId, payload, adapters_[i], gasLimit, refund);
        }

        return bytes32(0);
    }

    function _sendToAdapter(
        uint16 centrifugeId,
        bytes32 payloadId,
        bytes calldata payload,
        IAdapter adapter,
        uint256 gasLimit,
        address refund
    ) internal {
        uint256 cost = adapter.estimate(centrifugeId, payload, gasLimit);
        bytes32 adapterData = adapter.send{value: cost}(centrifugeId, payload, gasLimit, refund);
        emit SendPayload(centrifugeId, payloadId, payload, adapter, adapterData, gasLimit, cost, refund);
    }

    /// @inheritdoc IAdapter
    function estimate(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit)
        external
        view
        returns (uint256 total)
    {
        PoolId poolId = messageProperties.messagePoolId(payload);
        IAdapter[] memory adapters_ = poolAdapters(centrifugeId, poolId);

        for (uint256 i; i < adapters_.length; i++) {
            total += adapters_[i].estimate(centrifugeId, payload, gasLimit);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Getters
    //----------------------------------------------------------------------------------------------

    function poolAdapters(uint16 centrifugeId, PoolId poolId) public view returns (IAdapter[] memory adapters_) {
        adapters_ = adapters[centrifugeId][poolId];

        // If adapters not configured per pool, then use the global adapters
        if (adapters_.length == 0) adapters_ = adapters[centrifugeId][GLOBAL_POOL];
    }

    function _poolAdapterDetails(uint16 centrifugeId, PoolId poolId, IAdapter adapterAddr)
        internal
        view
        returns (Adapter memory adapter)
    {
        adapter = _adapterDetails[centrifugeId][poolId][adapterAddr];

        // If adapters not configured per pool, then assume it's received by a global adapters
        if (adapter.id == 0 && adapters[centrifugeId][poolId].length == 0) {
            adapter = _adapterDetails[centrifugeId][GLOBAL_POOL][adapterAddr];
        }
    }

    /// @inheritdoc IMultiAdapter
    function quorum(uint16 centrifugeId, PoolId poolId) external view returns (uint8) {
        return _getFirstAdapterDetails(centrifugeId, poolId).quorum;
    }

    /// @inheritdoc IMultiAdapter
    function threshold(uint16 centrifugeId, PoolId poolId) external view returns (uint8) {
        return _getFirstAdapterDetails(centrifugeId, poolId).threshold;
    }

    /// @inheritdoc IMultiAdapter
    function recoveryIndex(uint16 centrifugeId, PoolId poolId) external view returns (uint8) {
        return _getFirstAdapterDetails(centrifugeId, poolId).recoveryIndex;
    }

    /// @inheritdoc IMultiAdapter
    function activeSessionId(uint16 centrifugeId, PoolId poolId) external view returns (uint64) {
        return _getFirstAdapterDetails(centrifugeId, poolId).activeSessionId;
    }

    /// @inheritdoc IMultiAdapter
    function votes(uint16 centrifugeId, bytes32 payloadHash) external view returns (int16[MAX_ADAPTER_COUNT] memory) {
        return inbound[centrifugeId][payloadHash].votes;
    }

    /// @dev Internal helper to get the first adapter's details for a pool, handling empty cases
    function _getFirstAdapterDetails(uint16 centrifugeId, PoolId poolId) internal view returns (Adapter memory) {
        IAdapter[] memory adapters_ = poolAdapters(centrifugeId, poolId);
        if (adapters_.length == 0) return Adapter(0, 0, 0, 0, 0);
        return _poolAdapterDetails(centrifugeId, poolId, adapters_[0]);
    }
}
