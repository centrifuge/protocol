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

import {PoolId} from "../types/PoolId.sol";

/// @title  MultiAdapter
/// @notice This contract manages multiple cross-chain messaging adapters and implements a voting mechanism
///         to ensure message consensus, requiring a configurable threshold of adapter confirmations before
///         forwarding messages to the gateway for execution.
contract MultiAdapter is Auth, IMultiAdapter {
    using CastLib for *;

    using MathLib for uint256;
    using ArrayLib for int16[8];

    uint16 public immutable localCentrifugeId;

    IMessageHandler public gateway;
    IMessageProperties public messageProperties;

    mapping(PoolId => mapping(address => bool)) public manager;

    mapping(uint16 centrifugeId => mapping(PoolId => uint16)) public activeSessionId;
    mapping(uint16 centrifugeId => mapping(PoolId => Adapters)) internal _activeAdapters;
    mapping(uint16 centrifugeId => mapping(PoolId => mapping(uint16 sessionId => IAdapter[]))) public adapters;
    mapping(
        uint16 centrifugeId => mapping(PoolId => mapping(uint16 sessionId => mapping(IAdapter adapter => Adapter)))
    ) internal _adapterDetails;

    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => int16[MAX_ADAPTER_COUNT])) internal _votes;

    constructor(uint16 localCentrifugeId_, IMessageHandler gateway_, address deployer) Auth(deployer) {
        localCentrifugeId = localCentrifugeId_;
        gateway = gateway_;
    }

    modifier onlyAuthOrManager(PoolId poolId) {
        require(wards[msg.sender] == 1 || manager[poolId][msg.sender], NotAuthorized());
        _;
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
    ) external onlyAuthOrManager(poolId) {
        uint8 quorum_ = addresses.length.toUint8();
        require(quorum_ <= MAX_ADAPTER_COUNT, ExceedsMax());
        require(threshold_ <= quorum_, ThresholdHigherThanQuorum());
        require(recoveryIndex_ <= quorum_, RecoveryIndexHigherThanQuorum());

        // Increment session id to reset pending votes, wrapping from max back to 1 (skipping 0)
        uint16 sessionId;
        unchecked {
            sessionId = activeSessionId[centrifugeId][poolId] + 1;
        }
        if (sessionId == 0) sessionId = 1;
        activeSessionId[centrifugeId][poolId] = sessionId;

        // Enable new adapters, setting quorum to number of adapters
        for (uint8 j; j < quorum_; j++) {
            require(_adapterDetails[centrifugeId][poolId][sessionId][addresses[j]].id == 0, NoDuplicatesAllowed());

            // Ids are assigned sequentially starting at 1
            _adapterDetails[centrifugeId][poolId][sessionId][addresses[j]] =
                Adapter(j + 1, quorum_, threshold_, recoveryIndex_);
        }

        adapters[centrifugeId][poolId][sessionId] = addresses;
        _activeAdapters[centrifugeId][poolId] = Adapters(sessionId, addresses);

        emit SetAdapters(centrifugeId, poolId, addresses, threshold_, recoveryIndex_);
    }

    /// @inheritdoc IMultiAdapter
    function denySession(uint16 centrifugeId, PoolId poolId, uint16 sessionId) external onlyAuthOrManager(poolId) {
        uint256 numAdapters = adapters[centrifugeId][poolId][sessionId].length;

        for (uint8 i; i < numAdapters; i++) {
            IAdapter adapter = adapters[centrifugeId][poolId][sessionId][i];
            delete _adapterDetails[centrifugeId][poolId][sessionId][adapter];
        }

        delete adapters[centrifugeId][poolId][sessionId];

        // If the session is the active one, we also remove the capability of sending messages through the adapters
        if (sessionId == activeSessionId[centrifugeId][poolId]) {
            delete _activeAdapters[centrifugeId][poolId];
        }

        emit DenySession(centrifugeId, poolId, sessionId);
    }

    /// @inheritdoc IMultiAdapter
    function updateManager(PoolId poolId, address who, bool canManage) external auth {
        manager[poolId][who] = canManage;
        emit UpdateManager(poolId, who, canManage);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageHandler
    function handle(uint16 centrifugeId, bytes calldata payload) external {
        uint16 sessionId = uint16(bytes2(payload[0:2]));
        bytes calldata unwrappedPayload = payload[2:];
        PoolId poolId = _routePoolId(centrifugeId, unwrappedPayload);

        IAdapter adapterAddr = IAdapter(msg.sender);
        Adapter memory adapter = _adapterDetails[centrifugeId][poolId][sessionId][adapterAddr];
        require(adapter.id != 0, InvalidAdapter());

        // Verify adapter and parse message hash
        bytes32 payloadHash = keccak256(payload);
        bytes32 payloadId = keccak256(abi.encodePacked(centrifugeId, localCentrifugeId, payloadHash));
        emit HandlePayload(centrifugeId, payloadId, payload, adapterAddr);

        int16[MAX_ADAPTER_COUNT] storage votes_ = _votes[centrifugeId][payloadHash];
        votes_[adapter.id - 1]++;

        if (votes_.countPositiveValues(adapter.quorum) >= adapter.threshold) {
            // Reduce votes by quorum
            votes_.decreaseFirstNValues(adapter.quorum, adapter.recoveryIndex);

            gateway.handle(centrifugeId, unwrappedPayload);
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
        PoolId poolId = _routePoolId(centrifugeId, payload);
        Adapters memory adapters_ = _activeAdapters[centrifugeId][poolId];
        require(adapters_.list.length != 0, EmptyAdapterSet());

        bytes memory wrappedPayload = abi.encodePacked(adapters_.sessionId, payload);

        bytes32 payloadId = keccak256(abi.encodePacked(localCentrifugeId, centrifugeId, keccak256(wrappedPayload)));
        for (uint256 i = 0; i < adapters_.list.length; i++) {
            _sendToAdapter(centrifugeId, payloadId, wrappedPayload, adapters_.list[i], gasLimit, refund);
        }

        return bytes32(0);
    }

    function _sendToAdapter(
        uint16 centrifugeId,
        bytes32 payloadId,
        bytes memory payload,
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
        PoolId poolId = _routePoolId(centrifugeId, payload);
        IAdapter[] memory adapters_ = _activeAdapters[centrifugeId][poolId].list;
        require(adapters_.length != 0, EmptyAdapterSet());

        // Account for the 2-byte session id prefix added in send().
        // Using non zero bytes to assume max cost as calldata
        bytes memory wrappedPayload = abi.encodePacked(uint16((1 << 8) + 1), payload);

        for (uint256 i; i < adapters_.length; i++) {
            total += adapters_[i].estimate(centrifugeId, wrappedPayload, gasLimit);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Getters
    //----------------------------------------------------------------------------------------------

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
    function votes(uint16 centrifugeId, bytes32 payloadHash) external view returns (int16[MAX_ADAPTER_COUNT] memory) {
        return _votes[centrifugeId][payloadHash];
    }

    /// @inheritdoc IMultiAdapter
    function activeAdapters(uint16 centrifugeId, PoolId poolId) external view returns (Adapters memory) {
        return _activeAdapters[centrifugeId][poolId];
    }

    /// @dev Resolves which pool's adapter set routes/verifies a message. The policy lives in
    ///      `messageProperties.routePoolId`; here we only supply whether the message's own pool already has
    ///      a set, letting an unconfigured pool fall back to the global set (see IMessageProperties). Send
    ///      and handle apply the same rule, so both chains agree on the carrying set.
    function _routePoolId(uint16 centrifugeId, bytes calldata payload) internal view returns (PoolId) {
        PoolId poolId = messageProperties.messagePoolId(payload);
        bool poolConfigured = _activeAdapters[centrifugeId][poolId].list.length != 0;
        return messageProperties.routePoolId(payload, poolConfigured);
    }

    /// @dev Internal helper to get the first adapter's details for a pool, handling empty cases
    function _getFirstAdapterDetails(uint16 centrifugeId, PoolId poolId) internal view returns (Adapter memory) {
        Adapters memory adapters_ = _activeAdapters[centrifugeId][poolId];
        if (adapters_.list.length == 0) return Adapter(0, 0, 0, 0);
        return _adapterDetails[centrifugeId][poolId][adapters_.sessionId][adapters_.list[0]];
    }
}
