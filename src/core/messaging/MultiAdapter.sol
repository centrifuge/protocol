// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "./interfaces/IAdapter.sol";
import {IMessageHandler} from "./interfaces/IMessageHandler.sol";
import {IAdapterEntrypoint} from "./interfaces/IAdapterEntrypoint.sol";
import {IMessageProperties} from "./interfaces/IMessageProperties.sol";
import {IMultiAdapter, MAX_ADAPTER_COUNT} from "./interfaces/IMultiAdapter.sol";

import {Auth} from "../../misc/Auth.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {ArrayLib} from "../../misc/libraries/ArrayLib.sol";
import {SafeTransferLib} from "../../misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../types/PoolId.sol";

/// @title  MultiAdapter
/// @notice This contract manages multiple cross-chain messaging adapters and implements a voting mechanism
///         to ensure message consensus, requiring a configurable threshold of adapter confirmations before
///         forwarding messages to the gateway for execution.
contract MultiAdapter is Auth, IMultiAdapter {
    using CastLib for *;
    using MathLib for uint256;
    using ArrayLib for int16[8];

    // Parameters
    uint16 public immutable localCentrifugeId;

    // Dependencies
    IMessageHandler public gateway;
    IMessageProperties public messageProperties;

    // Authorization
    mapping(PoolId => mapping(address => bool)) public manager;

    // Adapters & sessions
    mapping(uint16 centrifugeId => mapping(PoolId => uint16)) public activeSessionId;
    mapping(uint16 centrifugeId => mapping(PoolId => Adapters)) internal _activeAdapters;
    mapping(uint16 centrifugeId => mapping(PoolId => mapping(uint16 sessionId => IAdapter[]))) public adapters;
    mapping(
        uint16 centrifugeId => mapping(PoolId => mapping(uint16 sessionId => mapping(IAdapter adapter => Adapter)))
    ) internal _adapterDetails;
    mapping(uint16 centrifugeId => mapping(PoolId => mapping(uint16 sessionId => BlockedSession))) internal
        _blockedSessions;

    // Inbound messages
    mapping(uint16 centrifugeId => mapping(bytes32 voteKey => int16[MAX_ADAPTER_COUNT])) internal _votes;

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
    function updateManager(PoolId poolId, address who, bool canManage) external auth {
        manager[poolId][who] = canManage;
        emit UpdateManager(poolId, who, canManage);
    }

    //----------------------------------------------------------------------------------------------
    // Adapter management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMultiAdapter
    function setAdapters(
        uint16 centrifugeId,
        PoolId poolId,
        IAdapter[] calldata addresses,
        uint8 threshold_,
        uint16 targetSessionId
    ) external onlyAuthOrManager(poolId) {
        uint8 quorum_ = addresses.length.toUint8();
        require(quorum_ <= MAX_ADAPTER_COUNT, ExceedsMax());
        require(threshold_ > 0 || quorum_ == 0, ZeroThreshold());
        require(threshold_ <= quorum_, ThresholdHigherThanQuorum());

        // Advance the session id to reset pending votes
        uint16 sessionId = activeSessionId[centrifugeId][poolId] + 1;
        require(sessionId == targetSessionId, UnexpectedSessionId());
        activeSessionId[centrifugeId][poolId] = sessionId;

        _installSession(centrifugeId, poolId, sessionId, addresses, threshold_);
        _activeAdapters[centrifugeId][poolId] = Adapters(sessionId, addresses);

        emit SetAdapters(centrifugeId, poolId, sessionId, addresses, threshold_);
    }

    /// @inheritdoc IMultiAdapter
    function blockSession(uint16 centrifugeId, PoolId poolId, uint16 sessionId) external onlyAuthOrManager(poolId) {
        IAdapter[] memory list = adapters[centrifugeId][poolId][sessionId];
        uint256 numAdapters = list.length;
        require(numAdapters != 0, SessionNotConfigured());

        // Move the session configuration out of the live storage so handle()/send() reject it through their
        // existing checks (InvalidAdapter / EmptyAdapterSet), avoiding an extra SLOAD on every message.
        Adapter memory first = _adapterDetails[centrifugeId][poolId][sessionId][list[0]];
        bool wasActive = sessionId == activeSessionId[centrifugeId][poolId];
        _blockedSessions[centrifugeId][poolId][sessionId] = BlockedSession(first.threshold, wasActive, list);

        for (uint256 i; i < numAdapters; i++) {
            delete _adapterDetails[centrifugeId][poolId][sessionId][list[i]];
        }
        delete adapters[centrifugeId][poolId][sessionId];
        if (wasActive) delete _activeAdapters[centrifugeId][poolId];

        emit BlockSession(centrifugeId, poolId, sessionId);
    }

    /// @inheritdoc IMultiAdapter
    function unblockSession(uint16 centrifugeId, PoolId poolId, uint16 sessionId) external onlyAuthOrManager(poolId) {
        BlockedSession memory blocked = _blockedSessions[centrifugeId][poolId][sessionId];
        require(blocked.list.length != 0, SessionNotBlocked());

        // Move the configuration back into the live storage, rebuilding the per-adapter details.
        _installSession(centrifugeId, poolId, sessionId, blocked.list, blocked.threshold);

        // Only restore the active set if this is still the active session; a later setAdapters may have replaced it.
        if (blocked.wasActive && sessionId == activeSessionId[centrifugeId][poolId]) {
            _activeAdapters[centrifugeId][poolId] = Adapters(sessionId, blocked.list);
        }

        delete _blockedSessions[centrifugeId][poolId][sessionId];

        emit UnblockSession(centrifugeId, poolId, sessionId);
    }

    /// @dev Writes the per-adapter details and the session's adapter list, assigning ids sequentially from 1.
    function _installSession(
        uint16 centrifugeId,
        PoolId poolId,
        uint16 sessionId,
        IAdapter[] memory list,
        uint8 threshold_
    ) internal {
        uint8 quorum_ = list.length.toUint8();
        for (uint8 i; i < quorum_; i++) {
            require(_adapterDetails[centrifugeId][poolId][sessionId][list[i]].id == 0, NoDuplicatesAllowed());
            _adapterDetails[centrifugeId][poolId][sessionId][list[i]] = Adapter(i + 1, quorum_, threshold_);
        }
        adapters[centrifugeId][poolId][sessionId] = list;
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageHandler
    /// @dev Equivalent to vote() followed by execute(): cast this adapter's vote and, if it reaches the
    ///      threshold, consume the quorum's votes and forward to the gateway.
    function handle(uint16 centrifugeId, bytes calldata payload) external {
        handle(centrifugeId, payload, IAdapter(msg.sender));
    }

    /// @inheritdoc IMultiAdapter
    function handle(uint16 centrifugeId, bytes calldata payload, IAdapter adapter) public {
        (Adapter memory details, bytes32 payloadHash, bytes32 voteKey, bytes calldata unwrappedPayload) =
            _resolve(centrifugeId, payload, adapter);
        if (_vote(centrifugeId, payload, adapter, details, payloadHash, voteKey)) {
            _execute(centrifugeId, payload, adapter, details, payloadHash, voteKey, unwrappedPayload);
        }
    }

    /// @inheritdoc IAdapterEntrypoint
    function vote(uint16 centrifugeId, bytes calldata payload) external {
        vote(centrifugeId, payload, IAdapter(msg.sender));
    }

    /// @inheritdoc IMultiAdapter
    function vote(uint16 centrifugeId, bytes calldata payload, IAdapter adapter) public {
        (Adapter memory details, bytes32 payloadHash, bytes32 voteKey,) = _resolve(centrifugeId, payload, adapter);
        _vote(centrifugeId, payload, adapter, details, payloadHash, voteKey);
    }

    /// @inheritdoc IAdapterEntrypoint
    function execute(uint16 centrifugeId, bytes calldata payload) external {
        execute(centrifugeId, payload, IAdapter(msg.sender));
    }

    /// @inheritdoc IMultiAdapter
    function execute(uint16 centrifugeId, bytes calldata payload, IAdapter adapter) public {
        (Adapter memory details, bytes32 payloadHash, bytes32 voteKey, bytes calldata unwrappedPayload) =
            _resolve(centrifugeId, payload, adapter);

        require(
            _votes[centrifugeId][voteKey].countPositiveValues(details.quorum) >= details.threshold, NotEnoughVotes()
        );
        _execute(centrifugeId, payload, adapter, details, payloadHash, voteKey, unwrappedPayload);
    }

    /// @dev Record `adapter`'s vote, emit {Vote} and return whether the threshold has been reached. Votes
    ///      are NOT consumed here; consumption happens in `_execute()`.
    function _vote(
        uint16 centrifugeId,
        bytes calldata payload,
        IAdapter adapter,
        Adapter memory details,
        bytes32 payloadHash,
        bytes32 voteKey
    ) internal returns (bool reached) {
        _votes[centrifugeId][voteKey][details.id - 1]++;
        reached = _votes[centrifugeId][voteKey].countPositiveValues(details.quorum) >= details.threshold;

        bytes32 payloadId = keccak256(abi.encodePacked(centrifugeId, localCentrifugeId, payloadHash));
        emit Vote(centrifugeId, payloadId, payload, adapter);
    }

    /// @dev Consume the quorum's votes, forward the payload to the gateway and emit {Execute}. The
    ///      threshold check is the caller's responsibility (handle() via _vote()'s return, execute() via its require).
    function _execute(
        uint16 centrifugeId,
        bytes calldata payload,
        IAdapter adapter,
        Adapter memory details,
        bytes32 payloadHash,
        bytes32 voteKey,
        bytes calldata unwrappedPayload
    ) internal {
        _votes[centrifugeId][voteKey].decreaseFirstNValues(details.quorum);

        bytes32 payloadId = keccak256(abi.encodePacked(centrifugeId, localCentrifugeId, payloadHash));
        emit Execute(centrifugeId, payloadId, payload, adapter);

        gateway.handle(centrifugeId, unwrappedPayload);
    }

    /// @dev Parse a wrapped payload and resolve `adapter`'s config and the payload hash. The caller must be
    ///      `adapter` itself, or a manager of the payload's pool submitting on its behalf. Reverts if
    ///      `adapter` is not a configured adapter for the payload's pool/session.
    function _resolve(uint16 centrifugeId, bytes calldata payload, IAdapter adapter)
        internal
        view
        returns (Adapter memory details, bytes32 payloadHash, bytes32 voteKey, bytes calldata unwrappedPayload)
    {
        uint16 sessionId = uint16(bytes2(payload[0:2]));
        unwrappedPayload = payload[2:];
        PoolId poolId = _routePoolId(centrifugeId, unwrappedPayload);

        require(msg.sender == address(adapter) || manager[poolId][msg.sender], NotAuthorized());

        details = _adapterDetails[centrifugeId][poolId][sessionId][adapter];
        require(details.id != 0, InvalidAdapter());

        payloadHash = keccak256(payload);
        voteKey = keccak256(abi.encodePacked(poolId.raw(), payload));
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

        uint256 totalCost;
        for (uint256 i = 0; i < adapters_.list.length; i++) {
            totalCost += _sendToAdapter(centrifugeId, payloadId, wrappedPayload, adapters_.list[i], gasLimit, refund);
        }
        if (msg.value > totalCost) SafeTransferLib.safeTransferETH(refund, msg.value - totalCost);

        return bytes32(0);
    }

    function _sendToAdapter(
        uint16 centrifugeId,
        bytes32 payloadId,
        bytes memory payload,
        IAdapter adapter,
        uint256 gasLimit,
        address refund
    ) internal returns (uint256 cost) {
        cost = adapter.estimate(centrifugeId, payload, gasLimit);
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

        // Account for the 2-byte session id prefix added in send(); non-zero bytes for max calldata cost.
        bytes memory wrappedPayload = abi.encodePacked(uint16((1 << 8) + 1), payload);

        for (uint256 i; i < adapters_.length; i++) {
            total += adapters_[i].estimate(centrifugeId, wrappedPayload, gasLimit);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Getters
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMultiAdapter
    function blockedSession(uint16 centrifugeId, PoolId poolId, uint16 sessionId) external view returns (bool) {
        return _blockedSessions[centrifugeId][poolId][sessionId].list.length != 0;
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
    function votes(uint16 centrifugeId, bytes32 voteKey) external view returns (int16[MAX_ADAPTER_COUNT] memory) {
        return _votes[centrifugeId][voteKey];
    }

    /// @inheritdoc IMultiAdapter
    function activeAdapters(uint16 centrifugeId, PoolId poolId) external view returns (Adapters memory) {
        return _activeAdapters[centrifugeId][poolId];
    }

    /// @inheritdoc IMultiAdapter
    function nextActiveSessionId(uint16 centrifugeId, PoolId poolId) external view returns (uint16) {
        return activeSessionId[centrifugeId][poolId] + 1;
    }

    /// @dev Send and handle apply the same rule, so both chains agree on the carrying set.
    function _routePoolId(uint16 centrifugeId, bytes calldata payload) internal view returns (PoolId) {
        PoolId poolId = messageProperties.messagePoolId(payload);
        bool poolConfigured = activeSessionId[centrifugeId][poolId] != 0;
        return messageProperties.routePoolId(payload, poolConfigured);
    }

    function _getFirstAdapterDetails(uint16 centrifugeId, PoolId poolId) internal view returns (Adapter memory) {
        Adapters memory adapters_ = _activeAdapters[centrifugeId][poolId];
        if (adapters_.list.length == 0) return Adapter(0, 0, 0);
        return _adapterDetails[centrifugeId][poolId][adapters_.sessionId][adapters_.list[0]];
    }
}
