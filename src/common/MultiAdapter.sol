// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "./interfaces/IAdapter.sol";
import {MessageProofLib} from "./libraries/MessageProofLib.sol";
import {IMessageHandler} from "./interfaces/IMessageHandler.sol";
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

    uint8 public constant PRIMARY_ADAPTER_ID = 1;
    uint256 public constant RECOVERY_CHALLENGE_PERIOD = 7 days;

    uint16 public immutable localCentrifugeId;
    IMessageHandler public gateway;

    mapping(uint16 centrifugeId => IAdapter[]) public adapters;
    mapping(uint16 centrifugeId => mapping(IAdapter adapter => Adapter)) internal _adapterDetails;
    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => Inbound)) public inbound;
    mapping(uint16 centrifugeId => mapping(IAdapter adapter => mapping(bytes32 payloadHash => uint256 timestamp)))
        public recoveries;

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
        else revert FileUnrecognizedParam();

        emit File(what, instance);
    }

    /// @inheritdoc IMultiAdapter
    function file(bytes32 what, uint16 centrifugeId, IAdapter[] calldata addresses) external auth {
        if (what == "adapters") {
            uint8 quorum_ = addresses.length.toUint8();
            require(quorum_ != 0, EmptyAdapterSet());
            require(quorum_ <= MAX_ADAPTER_COUNT, ExceedsMax());

            // Increment session id to reset pending votes
            uint256 numAdapters = adapters[centrifugeId].length;
            uint64 sessionId =
                numAdapters > 0 ? _adapterDetails[centrifugeId][adapters[centrifugeId][0]].activeSessionId + 1 : 0;

            // Disable old adapters
            for (uint8 i; i < numAdapters; i++) {
                delete _adapterDetails[centrifugeId][adapters[centrifugeId][i]];
            }

            // Enable new adapters, setting quorum to number of adapters
            for (uint8 j; j < quorum_; j++) {
                require(_adapterDetails[centrifugeId][addresses[j]].id == 0, NoDuplicatesAllowed());

                // Ids are assigned sequentially starting at 1
                _adapterDetails[centrifugeId][addresses[j]] = Adapter(j + 1, quorum_, sessionId);
            }

            adapters[centrifugeId] = addresses;
        } else {
            revert FileUnrecognizedParam();
        }

        emit File(what, centrifugeId, addresses);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageHandler
    function handle(uint16 centrifugeId, bytes calldata payload) external {
        _handle(centrifugeId, payload, IAdapter(msg.sender));
    }

    function _handle(uint16 centrifugeId, bytes calldata payload, IAdapter adapter_) internal {
        Adapter memory adapter = _adapterDetails[centrifugeId][adapter_];
        require(adapter.id != 0, InvalidAdapter());

        // Verify adapter and parse message hash
        bytes32 payloadHash;
        bool isMessageProof = payload.toUint8(0) == MessageProofLib.MESSAGE_PROOF_ID;
        if (isMessageProof) {
            require(adapter.id != PRIMARY_ADAPTER_ID, NonProofAdapter());

            payloadHash = payload.deserializeMessageProof();
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
    function initiateRecovery(uint16 centrifugeId, IAdapter adapter, bytes32 payloadHash) external auth {
        require(_adapterDetails[centrifugeId][adapter].id != 0, InvalidAdapter());
        recoveries[centrifugeId][adapter][payloadHash] = block.timestamp + RECOVERY_CHALLENGE_PERIOD;
        emit InitiateRecovery(centrifugeId, payloadHash, adapter);
    }

    /// @inheritdoc IMultiAdapter
    function disputeRecovery(uint16 centrifugeId, IAdapter adapter, bytes32 payloadHash) external auth {
        require(recoveries[centrifugeId][adapter][payloadHash] != 0, RecoveryNotInitiated());
        delete recoveries[centrifugeId][adapter][payloadHash];
        emit DisputeRecovery(centrifugeId, payloadHash, adapter);
    }

    /// @inheritdoc IMultiAdapter
    function executeRecovery(uint16 centrifugeId, IAdapter adapter, bytes calldata payload) external {
        bytes32 payloadHash = keccak256(payload);
        uint256 recovery = recoveries[centrifugeId][adapter][payloadHash];

        require(recovery != 0, RecoveryNotInitiated());
        require(recovery <= block.timestamp, RecoveryChallengePeriodNotEnded());

        delete recoveries[centrifugeId][adapter][payloadHash];
        _handle(centrifugeId, payload, adapter);
        emit ExecuteRecovery(centrifugeId, payload, adapter);
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
        IAdapter[] memory adapters_ = adapters[centrifugeId];
        require(adapters_.length != 0, EmptyAdapterSet());

        bytes32 payloadHash = keccak256(payload);
        bytes32 payloadId = keccak256(abi.encodePacked(localCentrifugeId, centrifugeId, payloadHash));
        bytes memory proof = payloadHash.serializeMessageProof();

        uint256 cost = adapters_[0].estimate(centrifugeId, payload, gasLimit);
        bytes32 adapterData = adapters_[0].send{value: cost}(centrifugeId, payload, gasLimit, refund);
        emit SendPayload(centrifugeId, payloadId, payload, adapters_[0], adapterData, refund);

        for (uint256 i = 1; i < adapters_.length; i++) {
            cost = adapters_[i].estimate(centrifugeId, proof, gasLimit);
            adapterData = adapters_[i].send{value: cost}(centrifugeId, proof, gasLimit, refund);
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
        IAdapter[] memory adapters_ = adapters[centrifugeId];
        bytes memory proof = keccak256(payload).serializeMessageProof();

        for (uint256 i; i < adapters_.length; i++) {
            total += adapters_[i].estimate(centrifugeId, i == PRIMARY_ADAPTER_ID - 1 ? payload : proof, gasLimit);
        }
    }

    /// @inheritdoc IMultiAdapter
    function quorum(uint16 centrifugeId) external view returns (uint8) {
        Adapter memory adapter = _adapterDetails[centrifugeId][adapters[centrifugeId][0]];
        return adapter.quorum;
    }

    /// @inheritdoc IMultiAdapter
    function activeSessionId(uint16 centrifugeId) external view returns (uint64) {
        Adapter memory adapter = _adapterDetails[centrifugeId][adapters[centrifugeId][0]];
        return adapter.activeSessionId;
    }

    /// @inheritdoc IMultiAdapter
    function votes(uint16 centrifugeId, bytes32 payloadHash) external view returns (uint16[MAX_ADAPTER_COUNT] memory) {
        return inbound[centrifugeId][payloadHash].votes;
    }
}
