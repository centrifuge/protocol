// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "./types/PoolId.sol";
import {IAdapter} from "./interfaces/IAdapter.sol";
import {MessageProofLib} from "./libraries/MessageProofLib.sol";
import {IMessageHandler} from "./interfaces/IMessageHandler.sol";
import {IMessageProperties} from "./interfaces/IMessageProperties.sol";
import {IMultiAdapter, MAX_ADAPTER_COUNT} from "./interfaces/IMultiAdapter.sol";

import {Auth} from "../misc/Auth.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {ArrayLib} from "../misc/libraries/ArrayLib.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";

contract MultiAdapter is Auth, IMultiAdapter {
    using CastLib for *;
    using MessageProofLib for *;
    using BytesLib for bytes;
    using ArrayLib for uint16[8];
    using MathLib for uint256;

    PoolId public constant GLOBAL_ID = PoolId.wrap(0);
    uint8 public constant PRIMARY_ADAPTER_ID = 1;

    uint16 public immutable localCentrifugeId;
    IMessageHandler public gateway;
    IMessageProperties public messageProperties;

    mapping(PoolId => address) public manager;
    mapping(uint16 centrifugeId => mapping(PoolId => bool)) public isSendingBlocked;
    mapping(uint16 centrifugeId => mapping(PoolId => IAdapter[])) public adapters;
    mapping(uint16 centrifugeId => mapping(PoolId => mapping(IAdapter adapter => Adapter))) internal _adapterDetails;
    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => Inbound)) public inbound;

    constructor(
        uint16 localCentrifugeId_,
        IMessageHandler gateway_,
        IMessageProperties messageProperties_,
        address deployer
    ) Auth(deployer) {
        localCentrifugeId = localCentrifugeId_;
        gateway = gateway_;
        messageProperties = messageProperties_;
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
    function setAdapters(uint16 centrifugeId, PoolId poolId, IAdapter[] calldata addresses) external auth {
        uint8 quorum_ = addresses.length.toUint8();
        require(quorum_ != 0, EmptyAdapterSet());
        require(quorum_ <= MAX_ADAPTER_COUNT, ExceedsMax());

        // Increment session id to reset pending votes
        uint256 numAdapters = adapters[centrifugeId][poolId].length;
        uint64 sessionId = numAdapters > 0
            ? _adapterDetails[centrifugeId][poolId][adapters[centrifugeId][poolId][0]].activeSessionId + 1
            : 0;

        // Disable old adapters
        for (uint8 i; i < numAdapters; i++) {
            delete _adapterDetails[centrifugeId][poolId][adapters[centrifugeId][poolId][i]];
        }

        // Enable new adapters, setting quorum to number of adapters
        for (uint8 j; j < quorum_; j++) {
            require(_adapterDetails[centrifugeId][poolId][addresses[j]].id == 0, NoDuplicatesAllowed());

            // Ids are assigned sequentially starting at 1
            _adapterDetails[centrifugeId][poolId][addresses[j]] = Adapter(j + 1, quorum_, sessionId);
        }

        adapters[centrifugeId][poolId] = addresses;
        emit SetAdapters(centrifugeId, poolId, addresses);
    }

    /// @inheritdoc IMultiAdapter
    function setManager(PoolId poolId, address manager_) external auth {
        manager[poolId] = manager_;
        emit SetManager(poolId, manager_);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageHandler
    function handle(uint16 centrifugeId, bytes calldata payload) external {
        _handle(centrifugeId, payload, IAdapter(msg.sender));
    }

    function _handle(uint16 centrifugeId, bytes calldata payload, IAdapter adapter_) internal {
        bool isMessageProof = payload.toUint8(0) == MessageProofLib.MESSAGE_PROOF_ID;

        PoolId poolId;
        if (isMessageProof) poolId = payload.proofPoolId();
        else poolId = messageProperties.messagePoolId(payload);

        Adapter memory adapter = _adapterDetails[centrifugeId][poolId][adapter_];

        // If adapters not configured per pool, then assume it's received by a global adapters
        if (adapter.id == 0) adapter = _adapterDetails[centrifugeId][PoolId.wrap(0)][adapter_];

        require(adapter.id != 0, InvalidAdapter());

        // Verify adapter and parse message hash
        bytes32 payloadHash;
        if (isMessageProof) {
            require(adapter.id != PRIMARY_ADAPTER_ID, NonProofAdapter());

            payloadHash = payload.proofHash();
            bytes32 payloadId = keccak256(abi.encodePacked(centrifugeId, localCentrifugeId, payloadHash));
            emit HandleProof(centrifugeId, payloadId, payloadHash, adapter_);
        } else {
            require(adapter.id == PRIMARY_ADAPTER_ID, NonPayloadAdapter());

            payloadHash = keccak256(payload);
            bytes32 payloadId = keccak256(abi.encodePacked(centrifugeId, localCentrifugeId, payloadHash));
            emit HandlePayload(centrifugeId, payloadId, payload, adapter_);
        }

        // Special case for gas efficiency
        if (adapter.quorum == 1 && !isMessageProof) {
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

        if (state.votes.countNonZeroValues() >= adapter.quorum) {
            // Reduce votes by quorum
            state.votes.decreaseFirstNValues(adapter.quorum);

            if (isMessageProof) {
                gateway.handle(centrifugeId, state.pending);
            } else {
                gateway.handle(centrifugeId, payload);
            }

            // Only if there are no more pending messages, remove the pending message
            if (state.votes.isEmpty()) {
                delete state.pending;
            }
        } else if (!isMessageProof) {
            state.pending = payload;
        }
    }

    /// @inheritdoc IMultiAdapter
    function executeRecovery(uint16 centrifugeId, PoolId poolId, IAdapter adapter, bytes calldata payload) external {
        require(msg.sender == manager[poolId], ManagerNotAllowed());
        _handle(centrifugeId, payload, adapter);
        emit ExecuteRecovery(centrifugeId, payload, adapter);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    function send(uint16 centrifugeId, bytes memory payload, uint256 gasLimit, address refund)
        external
        payable
        auth
        returns (bytes32)
    {
        PoolId poolId = messageProperties.messagePoolId(payload);
        require(!isSendingBlocked[centrifugeId][poolId], SendingBlocked());

        IAdapter[] memory adapters_ = poolAdapters(centrifugeId, poolId);

        require(adapters_.length != 0, EmptyAdapterSet());

        bytes32 payloadHash = keccak256(payload);
        bytes32 payloadId = keccak256(abi.encodePacked(localCentrifugeId, centrifugeId, payloadHash));

        uint256 cost = adapters_[0].estimate(centrifugeId, payload, gasLimit);
        bytes32 adapterData = adapters_[0].send{value: cost}(centrifugeId, payload, gasLimit, refund);
        emit SendPayload(centrifugeId, payloadId, payload, adapters_[0], adapterData, refund);

        // Override the payload variable to send the proof to the remaining adapters
        payload = MessageProofLib.createMessageProof(poolId, payloadHash);
        for (uint256 i = 1; i < adapters_.length; i++) {
            cost = adapters_[i].estimate(centrifugeId, payload, gasLimit);
            adapterData = adapters_[i].send{value: cost}(centrifugeId, payload, gasLimit, refund);
            emit SendProof(centrifugeId, payloadId, payloadHash, adapters_[i], adapterData);
        }

        return bytes32(0);
    }

    /// @inheritdoc IAdapter
    function estimate(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit)
        external
        view
        returns (uint256 total)
    {
        PoolId poolId = messageProperties.messagePoolId(payload);
        IAdapter[] memory adapters_ = poolAdapters(centrifugeId, poolId);
        bytes memory proof = MessageProofLib.createMessageProof(poolId, keccak256(payload));

        for (uint256 i; i < adapters_.length; i++) {
            total += adapters_[i].estimate(centrifugeId, i == PRIMARY_ADAPTER_ID - 1 ? payload : proof, gasLimit);
        }
    }

    /// @inheritdoc IMultiAdapter
    function enableSending(uint16 centrifugeId, PoolId poolId, bool canSend) external {
        require(msg.sender == manager[poolId], ManagerNotAllowed());
        isSendingBlocked[centrifugeId][poolId] = !canSend;
        emit EnableSending(centrifugeId, poolId, canSend);
    }

    //----------------------------------------------------------------------------------------------
    // Getters
    //----------------------------------------------------------------------------------------------

    function poolAdapters(uint16 centrifugeId, PoolId poolId) public view returns (IAdapter[] memory adapters_) {
        adapters_ = adapters[centrifugeId][poolId];

        // If adapters not configured per pool, then use the global adapters
        if (adapters_.length == 0) adapters_ = adapters[centrifugeId][GLOBAL_ID];
    }

    /// @inheritdoc IMultiAdapter
    function quorum(uint16 centrifugeId, PoolId poolId) external view returns (uint8) {
        IAdapter adapter = adapters[centrifugeId][poolId][0];
        return _adapterDetails[centrifugeId][poolId][adapter].quorum;
    }

    /// @inheritdoc IMultiAdapter
    function activeSessionId(uint16 centrifugeId, PoolId poolId) external view returns (uint64) {
        IAdapter adapter = adapters[centrifugeId][poolId][0];
        return _adapterDetails[centrifugeId][poolId][adapter].activeSessionId;
    }

    /// @inheritdoc IMultiAdapter
    function votes(uint16 centrifugeId, bytes32 payloadHash) external view returns (uint16[MAX_ADAPTER_COUNT] memory) {
        return inbound[centrifugeId][payloadHash].votes;
    }
}
