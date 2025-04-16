// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {ArrayLib} from "src/misc/libraries/ArrayLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {Recoverable} from "src/misc/Recoverable.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";

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

    uint16 public immutable localCentrifugeId;

    // Dependencies
    IRoot public immutable root;
    IGasService public gasService;
    IMessageProcessor public processor;

    // Batching
    bool public transient isBatching;
    BatchLocator[] public /*transient*/ batchLocators;
    mapping(uint16 centrifugeId => mapping(PoolId => bytes)) public /*transient*/ outboundBatch;
    mapping(uint16 centrifugeId => mapping(PoolId => uint128)) public /*transient*/ batchGasLimit;

    // Payment
    uint256 public transient fuel;
    address public transient transactionPayer;
    mapping(PoolId => Funds) public subsidy;

    // Adapters
    mapping(uint16 centrifugeId => IAdapter[]) public adapters;
    mapping(uint16 centrifugeId => mapping(IAdapter adapter => Adapter)) internal _activeAdapters;

    // Messages
    mapping(uint16 centrifugeId => mapping(bytes32 messageHash => uint256)) public failedMessages;
    mapping(uint16 centrifugeId => mapping(bytes32 batchHash => InboundBatch)) public inboundBatch;
    mapping(uint16 centrifugeId => mapping(IAdapter adapter => mapping(bytes32 batchHash => uint256 timestamp))) public
        recoveries;

    constructor(uint16 localCentrifugeId_, IRoot root_, IGasService gasService_) Auth(msg.sender) {
        localCentrifugeId = localCentrifugeId_;
        root = root_;
        gasService = gasService_;

        setRefundAddress(PoolId.wrap(0), address(this));
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

    receive() external payable {
        subsidizePool(PoolId.wrap(0));
    }

    //----------------------------------------------------------------------------------------------
    // Incoming methods
    //----------------------------------------------------------------------------------------------

    /// @dev Handle an inbound payload
    function handle(uint16 centrifugeId, bytes calldata payload) external pauseable {
        _handle(centrifugeId, payload, IAdapter(msg.sender), false);
    }

    function _handle(uint16 centrifugeId, bytes calldata payload, IAdapter adapter_, bool isRecovery) internal {
        Adapter memory adapter = _activeAdapters[centrifugeId][adapter_];
        require(adapter.id != 0, InvalidAdapter());

        IMessageProcessor processor_ = processor;
        if (processor_.isMessageRecovery(payload)) {
            require(!isRecovery, RecoveryMessageRecovered());
            return processor_.handle(centrifugeId, payload);
        }

        bytes32 batchId = keccak256(abi.encodePacked(centrifugeId, localCentrifugeId, payload));
        bytes32 messageProofHash = processor_.messageProofHash(payload);
        bool isMessageProof = messageProofHash != bytes32(0);
        if (adapter.quorum == 1 && !isMessageProof) {
            // Special case for gas efficiency
            emit ProcessBatch(centrifugeId, batchId, payload, adapter_);
            _handleBatch(centrifugeId, payload);
            return;
        }

        // Verify adapter and parse message hash
        bytes32 batchHash;
        if (isMessageProof) {
            require(adapter.id != PRIMARY_ADAPTER_ID, NonProofAdapter());
            batchHash = messageProofHash;
            emit ProcessProof(centrifugeId, batchId, batchHash, adapter_);
        } else {
            require(adapter.id == PRIMARY_ADAPTER_ID, NonBatchAdapter());
            batchHash = keccak256(payload);
            emit ProcessBatch(centrifugeId, batchId, payload, adapter_);
        }

        InboundBatch storage state = inboundBatch[centrifugeId][batchHash];

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
                _handleBatch(centrifugeId, state.pendingBatch);
            } else {
                _handleBatch(centrifugeId, payload);
            }

            // Only if there are no more pending messages, remove the pending message
            if (state.votes.isEmpty()) {
                delete state.pendingBatch;
            }
        } else if (!isMessageProof) {
            state.pendingBatch = payload;
        }
    }

    function _handleBatch(uint16 centrifugeId, bytes memory batch_) internal {
        bytes memory message = batch_;
        IMessageProcessor processor_ = processor;
        for (uint256 start; start < batch_.length;) {
            uint256 length = processor_.messageLength(message);
            message = batch_.slice(start, length);
            start += length;

            try processor_.handle(centrifugeId, message) {
                emit ExecuteMessage(centrifugeId, message);
            } catch (bytes memory err) {
                bytes32 messageHash = keccak256(message);
                failedMessages[centrifugeId][messageHash]++;
                emit FailMessage(centrifugeId, message, err);
            }
        }
    }

    function retry(uint16 centrifugeId, bytes memory message) external pauseable {
        bytes32 messageHash = keccak256(message);
        require(failedMessages[centrifugeId][messageHash] > 0, NotFailedMessage());

        processor.handle(centrifugeId, message);
        failedMessages[centrifugeId][messageHash]--;

        emit ExecuteMessage(centrifugeId, message);
    }

    /// @inheritdoc IGatewayHandler
    function initiateMessageRecovery(uint16 centrifugeId, IAdapter adapter, bytes32 batchHash) external auth {
        require(_activeAdapters[centrifugeId][adapter].id != 0, InvalidAdapter());
        recoveries[centrifugeId][adapter][batchHash] = block.timestamp + RECOVERY_CHALLENGE_PERIOD;
        emit InitiateMessageRecovery(centrifugeId, batchHash, adapter);
    }

    /// @inheritdoc IGatewayHandler
    function disputeMessageRecovery(uint16 centrifugeId, IAdapter adapter, bytes32 batchHash) external auth {
        delete recoveries[centrifugeId][adapter][batchHash];
        emit DisputeMessageRecovery(centrifugeId, batchHash, adapter);
    }

    /// @inheritdoc IGateway
    function executeMessageRecovery(uint16 centrifugeId, IAdapter adapter, bytes calldata message) external {
        bytes32 batchHash = keccak256(message);
        uint256 recovery = recoveries[centrifugeId][adapter][batchHash];

        require(recovery != 0, MessageRecoveryNotInitiated());
        require(recovery <= block.timestamp, MessageRecoveryChallengePeriodNotEnded());

        delete recoveries[centrifugeId][adapter][batchHash];
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

        emit PrepareMessage(centrifugeId, poolId, message);

        if (isBatching) {
            bytes storage previousMessage = outboundBatch[centrifugeId][poolId];

            batchGasLimit[centrifugeId][poolId] += gasService.gasLimit(centrifugeId, message);
            require(batchGasLimit[centrifugeId][poolId] <= gasService.maxBatchSize(centrifugeId), ExceedsMaxBatchSize());

            if (previousMessage.length == 0) {
                batchLocators.push(BatchLocator(centrifugeId, poolId));
                outboundBatch[centrifugeId][poolId] = message;
            } else {
                outboundBatch[centrifugeId][poolId] = bytes.concat(previousMessage, message);
            }
        } else {
            _send(centrifugeId, poolId, message);
            _closeTransaction();
        }
    }

    function _send(uint16 centrifugeId, PoolId poolId, bytes memory batch) private {
        bytes32 batchHash = keccak256(batch);
        bytes memory proof = processor.createMessageProof(batchHash);

        IAdapter[] memory adapters_ = adapters[centrifugeId];
        require(adapters[centrifugeId].length != 0, EmptyAdapterSet());

        uint128 batchGasLimit_ =
            (isBatching) ? batchGasLimit[centrifugeId][poolId] : gasService.gasLimit(centrifugeId, batch);

        for (uint256 i; i < adapters_.length; i++) {
            uint256 consumed =
                adapters_[i].estimate(centrifugeId, i == PRIMARY_ADAPTER_ID - 1 ? batch : proof, batchGasLimit_);

            if (transactionPayer != address(0)) {
                require(consumed <= fuel, NotEnoughTransactionGas());
                fuel -= consumed;
            } else {
                if (consumed <= subsidy[poolId].value) {
                    subsidy[poolId].value -= uint96(consumed);
                } else {
                    consumed = 0;
                }
            }

            adapters_[i].send{value: consumed}(
                centrifugeId,
                i == PRIMARY_ADAPTER_ID - 1 ? batch : proof,
                batchGasLimit_,
                transactionPayer != address(0) ? transactionPayer : subsidy[poolId].refund
            );

            if (i == PRIMARY_ADAPTER_ID - 1) {
                emit SendBatch(
                    centrifugeId,
                    keccak256(abi.encodePacked(localCentrifugeId, centrifugeId, batch)),
                    batch,
                    adapters_[i]
                );
            } else {
                emit SendProof(
                    centrifugeId,
                    keccak256(abi.encodePacked(localCentrifugeId, centrifugeId, batch)),
                    batchHash,
                    adapters_[i]
                );
            }
        }
    }

    function _closeTransaction() internal {
        if (transactionPayer == address(0)) return;

        if (fuel > 0) {
            (bool success,) = transactionPayer.call{value: fuel}(new bytes(0));

            if (!success) {
                // If refund fails, move remaining fuel to global pot
                subsidy[PoolId.wrap(0)].value += uint96(fuel);
                emit SubsidizePool(PoolId.wrap(0), address(this), fuel);
            }

            fuel = 0;
        }

        transactionPayer = address(0);
    }

    function setRefundAddress(PoolId poolId, address refund) public auth {
        subsidy[poolId].refund = refund;
        emit SetRefundAddress(poolId, refund);
    }

    function subsidizePool(PoolId poolId) public payable {
        require(subsidy[poolId].refund != address(0), RefundAddressNotSet());
        subsidy[poolId].value += uint96(msg.value);
        emit SubsidizePool(poolId, msg.sender, msg.value);
    }

    /// @inheritdoc IGateway
    function payTransaction(address payer) external payable auth {
        transactionPayer = payer;
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
            _send(locator.centrifugeId, locator.poolId, outboundBatch[locator.centrifugeId][locator.poolId]);
            delete outboundBatch[locator.centrifugeId][locator.poolId];
            delete batchGasLimit[locator.centrifugeId][locator.poolId];
        }

        delete batchLocators;
        isBatching = false;

        _closeTransaction();
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IGateway
    function estimate(uint16 centrifugeId, bytes calldata payload) external view returns (uint256 total) {
        bytes memory proof = processor.createMessageProof(keccak256(payload));

        uint256 gasLimit = 0;
        for (uint256 pos; pos < payload.length;) {
            bytes calldata inner = payload[pos:payload.length];
            gasLimit += gasService.gasLimit(centrifugeId, inner);
            pos += processor.messageLength(inner);
        }

        uint256 adaptersCount = adapters[centrifugeId].length;
        for (uint256 i; i < adaptersCount; i++) {
            bytes memory message = i == PRIMARY_ADAPTER_ID - 1 ? payload : proof;
            total += IAdapter(adapters[centrifugeId][i]).estimate(centrifugeId, message, gasLimit);
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
    function votes(uint16 centrifugeId, bytes32 batchHash) external view returns (uint16[MAX_ADAPTER_COUNT] memory) {
        return inboundBatch[centrifugeId][batchHash].votes;
    }
}
