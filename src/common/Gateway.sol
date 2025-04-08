// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {ArrayLib} from "src/misc/libraries/ArrayLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {Recoverable} from "src/misc/Recoverable.sol";

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IMessageProcessor} from "src/common/interfaces/IMessageProcessor.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {IGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";

/// @title  Gateway
/// @notice Routing contract that forwards outgoing messages to multiple adapters (1 full message, n-1 proofs)
///         and validates that multiple adapters have confirmed a message.
///         Handling incoming messages from the Centrifuge Chain through multiple adapters.
///         Supports processing multiple duplicate messages in parallel by
///         storing counts of messages and proofs that have been received.
contract Gateway is Auth, IGateway, Recoverable {
    using ArrayLib for uint16[8];
    using BytesLib for bytes;
    using MathLib for uint256;

    uint8 public constant MAX_ADAPTER_COUNT = 8;
    uint8 public constant PRIMARY_ADAPTER_ID = 1;
    uint256 public constant RECOVERY_CHALLENGE_PERIOD = 7 days;

    // Dependencies
    IRoot public immutable root;
    IGasService public gasService;
    IMessageProcessor public processor;

    // Batching
    bool public transient isBatching;
    BatchLocator[] public /*transient*/ batchLocators;
    mapping(uint16 centrifugeId => mapping(PoolId => bytes)) public /*transient*/ batch;
    mapping(uint16 centrifugeId => mapping(PoolId => uint64)) public /*transient*/ batchGasLimit;

    // Payment
    PaymentMethod public transient paymentMethod;
    uint256 public transient fuel;
    mapping(PoolId => uint256) public subsidy;

    // Adapters
    mapping(uint16 centrifugeId => IAdapter[]) public adapters;
    mapping(uint16 centrifugeId => mapping(IAdapter adapter => Adapter)) internal _activeAdapters;

    // Messages
    mapping(uint16 centrifugeId => mapping(bytes32 messageHash => Message)) internal _messages;
    mapping(uint16 centrifugeId => mapping(IAdapter adapter => mapping(bytes32 messageHash => uint256 timestamp)))
        public recoveries;


    constructor(IRoot root_, IGasService gasService_) Auth(msg.sender) {
        root = root_;
        gasService = gasService_;
    }

    modifier pauseable() {
        require(!root.paused(), Paused());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IGateway
    function file(bytes32 what, uint16 centrifugeId, IAdapter[] calldata addresses) external auth {
        if (what == "adapters") {
            uint8 quorum_ = addresses.length.toUint8();
            require(quorum_ != 0, EmptyAdapterSet());
            require(quorum_ <= MAX_ADAPTER_COUNT, ExceedsMax());

            // Increment session id to reset pending votes
            uint256 numAdapters = adapters[centrifugeId].length;
            uint64 sessionId =
                numAdapters > 0 ? _activeAdapters[centrifugeId][adapters[centrifugeId][0]].activeSessionId + 1 : 0;

            // Disable old adapters
            for (uint8 i; i < numAdapters; i++) {
                delete _activeAdapters[centrifugeId][adapters[centrifugeId][i]];
            }

            // Enable new adapters, setting quorum to number of adapters
            for (uint8 j; j < quorum_; j++) {
                require(_activeAdapters[centrifugeId][addresses[j]].id == 0, NoDuplicatesAllowed());

                // Ids are assigned sequentially starting at 1
                _activeAdapters[centrifugeId][addresses[j]] = Adapter(j + 1, quorum_, sessionId);
            }

            adapters[centrifugeId] = addresses;
        } else {
            revert FileUnrecognizedParam();
        }

        emit File(what, centrifugeId, addresses);
    }

    /// @inheritdoc IGateway
    function file(bytes32 what, address instance) external auth {
        if (what == "gasService") gasService = IGasService(instance);
        else if (what == "processor") processor = IMessageProcessor(instance);
        else revert FileUnrecognizedParam();

        emit File(what, instance);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming methods
    //----------------------------------------------------------------------------------------------

    /// @dev Handle a batch of messages
    function handle(uint16 centrifugeId, bytes calldata message) external pauseable {
        for (uint256 pos; pos < message.length;) {
            bytes calldata inner = message[pos:message.length];
            _handle(centrifugeId, inner, IAdapter(msg.sender), false);
            pos += processor.messageLength(inner);
        }
    }

    /// @dev Handle an isolated message
    function _handle(uint16 centrifugeId, bytes calldata payload, IAdapter adapter_, bool isRecovery) internal {
        Adapter memory adapter = _activeAdapters[centrifugeId][adapter_];
        require(adapter.id != 0, InvalidAdapter());

        if (processor.isMessageRecovery(payload)) {
            require(!isRecovery, RecoveryMessageRecovered());
            return processor.handle(centrifugeId, payload);
        }

        bytes32 messageProofHash = processor.messageProofHash(payload);
        bool isMessageProof = messageProofHash != bytes32(0);
        if (adapter.quorum == 1 && !isMessageProof) {
            // Special case for gas efficiency
            processor.handle(centrifugeId, payload);
            emit ExecuteMessage(centrifugeId, payload, adapter_);
            return;
        }

        // Verify adapter and parse message hash
        bytes32 messageHash;
        if (isMessageProof) {
            require(adapter.id != PRIMARY_ADAPTER_ID, NonProofAdapter());
            messageHash = messageProofHash;
            emit ProcessProof(centrifugeId, messageHash, adapter_);
        } else {
            require(adapter.id == PRIMARY_ADAPTER_ID, NonMessageAdapter());
            messageHash = keccak256(payload);
            emit ProcessMessage(centrifugeId, payload, adapter_);
        }

        Message storage state = _messages[centrifugeId][messageHash];

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

            // Handle message
            if (isMessageProof) {
                processor.handle(centrifugeId, state.pendingMessage);
                emit ExecuteMessage(centrifugeId, state.pendingMessage, adapter_);
            } else {
                processor.handle(centrifugeId, payload);
                emit ExecuteMessage(centrifugeId, payload, adapter_);
            }

            // Only if there are no more pending messages, remove the pending message
            if (state.votes.isEmpty()) {
                delete state.pendingMessage;
            }
        } else if (!isMessageProof) {
            state.pendingMessage = payload;
        }
    }

    /// @inheritdoc IGatewayHandler
    function initiateMessageRecovery(uint16 centrifugeId, IAdapter adapter, bytes32 messageHash) external auth {
        require(_activeAdapters[centrifugeId][adapter].id != 0, InvalidAdapter());
        recoveries[centrifugeId][adapter][messageHash] = block.timestamp + RECOVERY_CHALLENGE_PERIOD;
        emit InitiateMessageRecovery(centrifugeId, messageHash, adapter);
    }

    /// @inheritdoc IGatewayHandler
    function disputeMessageRecovery(uint16 centrifugeId, IAdapter adapter, bytes32 messageHash) external auth {
        delete recoveries[centrifugeId][adapter][messageHash];
        emit DisputeMessageRecovery(centrifugeId, messageHash, adapter);
    }

    /// @inheritdoc IGateway
    function executeMessageRecovery(uint16 centrifugeId, IAdapter adapter, bytes calldata message) external {
        bytes32 messageHash = keccak256(message);
        uint256 recovery = recoveries[centrifugeId][adapter][messageHash];

        require(recovery != 0, MessageRecoveryNotInitiated());
        require(recovery <= block.timestamp, MessageRecoveryChallengePeriodNotEnded());

        delete recoveries[centrifugeId][adapter][messageHash];
        _handle(centrifugeId, message, adapter, true);
        emit ExecuteMessageRecovery(centrifugeId, message, adapter);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageSender
    function send(uint16 centrifugeId, bytes calldata message) external pauseable auth {
        require(message.length > 0, EmptyMessage());

        PoolId poolId = processor.messagePoolId(message);
        if (isBatching) {
            bytes storage previousMessage = batch[centrifugeId][poolId];

            batchGasLimit[centrifugeId][poolId] += gasService.gasLimit(centrifugeId, message);

            if (previousMessage.length == 0) {
                batchLocators.push(BatchLocator(centrifugeId, poolId));
                batch[centrifugeId][poolId] = message;
            } else {
                batch[centrifugeId][poolId] = bytes.concat(previousMessage, message);
            }
        } else {
            _send(centrifugeId, poolId, message);
        }
    }

    function _send(uint16 centrifugeId, PoolId poolId, bytes memory message) private {
        bytes memory proof = processor.createMessageProof(message);

        IAdapter[] memory adapters_ = adapters[centrifugeId];
        require(adapters[centrifugeId].length != 0, EmptyAdapterSet());

        uint64 messageGasLimit =
            (isBatching) ? batchGasLimit[centrifugeId][poolId] : gasService.gasLimit(centrifugeId, message);
        uint64 proofGasLimit = gasService.gasLimit(centrifugeId, proof);

        for (uint256 i; i < adapters_.length; i++) {
            IAdapter currentAdapter = IAdapter(adapters_[i]);
            bool isPrimaryAdapter = i == PRIMARY_ADAPTER_ID - 1;
            bytes memory payload = isPrimaryAdapter ? message : proof;
            uint64 gasLimit = isPrimaryAdapter ? messageGasLimit : proofGasLimit;

            uint256 consumed = currentAdapter.estimate(centrifugeId, payload, gasLimit);

            if (paymentMethod == PaymentMethod.Transaction) {
                require(consumed <= fuel, NotEnoughTransactionGas());
                fuel -= consumed;
            } else {
                if (consumed <= subsidy[poolId]) {
                    subsidy[poolId] -= consumed;
                } else {
                    consumed = 0;
                }
            }

            currentAdapter.send{value: consumed}(centrifugeId, payload, gasLimit, address(this));
        }

        emit SendMessage(message);
    }

    function subsidizePool(PoolId poolId) external payable {
        subsidy[poolId] += msg.value;
        emit SubsidizePool(poolId, msg.sender, msg.value);
    }

    /// @inheritdoc IGateway
    function payTransaction() external payable auth {
        paymentMethod = PaymentMethod.Transaction;
        fuel += msg.value;
    }

    /// @inheritdoc IGateway
    function startBatching() external auth {
        isBatching = true;
    }

    /// @inheritdoc IGateway
    function endBatching() external auth {
        require(isBatching, NoBatched());

        for (uint256 i; i < batchLocators.length; i++) {
            BatchLocator memory locator = batchLocators[i];
            _send(locator.centrifugeId, locator.poolId, batch[locator.centrifugeId][locator.poolId]);
            delete batch[locator.centrifugeId][locator.poolId];
            delete batchGasLimit[locator.centrifugeId][locator.poolId];
        }

        delete batchLocators;
        isBatching = false;
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IGateway
    function estimate(uint16 centrifugeId, bytes calldata payload)
        external
        view
        returns (uint256[] memory perAdapter, uint256 total)
    {
        bytes memory proof = processor.createMessageProof(payload);

        uint256 proofGasLimit = gasService.gasLimit(centrifugeId, proof);

        uint256 messageGasLimit = 0;
        for (uint256 pos; pos < payload.length;) {
            bytes calldata inner = payload[pos:payload.length];
            messageGasLimit += gasService.gasLimit(centrifugeId, inner);
            pos += processor.messageLength(inner);
        }

        perAdapter = new uint256[](adapters[centrifugeId].length);

        uint256 adaptersCount = adapters[centrifugeId].length;
        for (uint256 i; i < adaptersCount; i++) {
            uint256 gasLimit_ = i == PRIMARY_ADAPTER_ID - 1 ? messageGasLimit : proofGasLimit;
            bytes memory message = i == PRIMARY_ADAPTER_ID - 1 ? payload : proof;
            uint256 estimated = IAdapter(adapters[centrifugeId][i]).estimate(centrifugeId, message, gasLimit_);
            perAdapter[i] = estimated;
            total += estimated;
        }
    }

    /// @inheritdoc IGateway
    function quorum(uint16 centrifugeId) external view returns (uint8) {
        Adapter memory adapter = _activeAdapters[centrifugeId][adapters[centrifugeId][0]];
        return adapter.quorum;
    }

    /// @inheritdoc IGateway
    function activeSessionId(uint16 centrifugeId) external view returns (uint64) {
        Adapter memory adapter = _activeAdapters[centrifugeId][adapters[centrifugeId][0]];
        return adapter.activeSessionId;
    }

    /// @inheritdoc IGateway
    function votes(uint16 centrifugeId, bytes32 messageHash) external view returns (uint16[MAX_ADAPTER_COUNT] memory) {
        return _messages[centrifugeId][messageHash].votes;
    }

    /// @inheritdoc IGateway
    function adapterCount(uint16 centrifugeId) external view returns (uint256) {
        return adapters[centrifugeId].length;
    }
}
