// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {ArrayLib} from "src/misc/libraries/ArrayLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {Recoverable, IRecoverable, ETH_ADDRESS} from "src/misc/Recoverable.sol";
import {TransientArrayLib} from "src/misc/libraries/TransientArrayLib.sol";
import {TransientBytesLib} from "src/misc/libraries/TransientBytesLib.sol";
import {TransientStorageLib} from "src/misc/libraries/TransientStorageLib.sol";

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IMessageProcessor} from "src/common/interfaces/IMessageProcessor.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {IGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {MessageProofLib} from "src/common/libraries/MessageProofLib.sol";

/// @title  Gateway
/// @notice Routing contract that forwards outgoing messages to multiple adapters (1 full message, n-1 proofs)
///         and validates that multiple adapters have confirmed a message.
///
///         Supports batching multiple messages, as well as paying for methods manually or through pool-level subsidies.
///
///         Supports processing multiple duplicate messages in parallel by storing counts of messages
///         and proofs that have been received. Also implements a retry method for failed messages.
contract Gateway is Auth, Recoverable, IGateway {
    using BytesLib for bytes;
    using MathLib for uint256;
    using MessageProofLib for *;
    using ArrayLib for uint16[8];
    using TransientStorageLib for bytes32;

    uint8 public constant MAX_ADAPTER_COUNT = 8;
    uint8 public constant PRIMARY_ADAPTER_ID = 1;
    PoolId public constant GLOBAL_POT = PoolId.wrap(0);
    uint256 public constant RECOVERY_CHALLENGE_PERIOD = 7 days;
    bytes32 public constant BATCH_LOCATORS_SLOT = bytes32(uint256(keccak256("Centrifuge/batch-locators")) - 1);

    uint16 public immutable localCentrifugeId;

    // Dependencies
    IRoot public immutable root;
    IGasService public gasService;
    IMessageProcessor public processor;

    // Outbound & payments
    bool public transient isBatching;
    uint256 public transient fuel;
    address public transient transactionRefund;
    mapping(PoolId => Funds) public subsidy;
    mapping(uint16 centrifugeId => mapping(bytes32 batchHash => uint256)) public underpaid;

    // Adapters
    mapping(uint16 centrifugeId => IAdapter[]) public adapters;
    mapping(uint16 centrifugeId => mapping(IAdapter adapter => Adapter)) internal _activeAdapters;

    // Inbound & recoveries
    mapping(uint16 centrifugeId => mapping(bytes32 messageHash => uint256)) public failedMessages;
    mapping(uint16 centrifugeId => mapping(bytes32 batchHash => InboundBatch)) public inboundBatch;
    mapping(uint16 centrifugeId => mapping(IAdapter adapter => mapping(bytes32 payloadHash => uint256 timestamp)))
        public recoveries;

    constructor(uint16 localCentrifugeId_, IRoot root_, IGasService gasService_, address deployer) Auth(deployer) {
        localCentrifugeId = localCentrifugeId_;
        root = root_;
        gasService = gasService_;

        setRefundAddress(GLOBAL_POT, IRecoverable(address(this)));
    }

    modifier pauseable() {
        require(!root.paused(), Paused());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
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
        _subsidizePool(GLOBAL_POT, msg.sender, msg.value);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
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
            require(!isRecovery, RecoveryPayloadRecovered());
            return processor_.handle(centrifugeId, payload);
        }

        bool isMessageProof = payload.toUint8(0) == MessageProofLib.MESSAGE_PROOF_ID;

        // Verify adapter and parse message hash
        bytes32 batchHash;
        if (isMessageProof) {
            require(adapter.id != PRIMARY_ADAPTER_ID, NonProofAdapter());

            batchHash = payload.deserializeMessageProof();
            bytes32 payloadId = keccak256(abi.encodePacked(centrifugeId, localCentrifugeId, batchHash));
            emit HandleProof(centrifugeId, payloadId, batchHash, adapter_);
        } else {
            require(adapter.id == PRIMARY_ADAPTER_ID, NonBatchAdapter());

            batchHash = keccak256(payload);
            bytes32 payloadId = keccak256(abi.encodePacked(centrifugeId, localCentrifugeId, batchHash));
            emit HandleBatch(centrifugeId, payloadId, payload, adapter_);
        }

        // Special case for gas efficiency
        if (adapter.quorum == 1 && !isMessageProof) {
            _handleBatch(centrifugeId, payload);
            return;
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
        IMessageProcessor processor_ = processor;
        bytes memory remaining = batch_;

        while (remaining.length > 0) {
            uint256 length = processor_.messageLength(remaining);
            bytes memory message = remaining.slice(0, length);
            remaining = remaining.slice(length, remaining.length - length);

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
    function initiateRecovery(uint16 centrifugeId, IAdapter adapter, bytes32 payloadHash) external auth {
        require(_activeAdapters[centrifugeId][adapter].id != 0, InvalidAdapter());
        recoveries[centrifugeId][adapter][payloadHash] = block.timestamp + RECOVERY_CHALLENGE_PERIOD;
        emit InitiateRecovery(centrifugeId, payloadHash, adapter);
    }

    /// @inheritdoc IGatewayHandler
    function disputeRecovery(uint16 centrifugeId, IAdapter adapter, bytes32 payloadHash) external auth {
        delete recoveries[centrifugeId][adapter][payloadHash];
        emit DisputeRecovery(centrifugeId, payloadHash, adapter);
    }

    /// @inheritdoc IGateway
    function executeRecovery(uint16 centrifugeId, IAdapter adapter, bytes calldata payload) external {
        bytes32 payloadHash = keccak256(payload);
        uint256 recovery = recoveries[centrifugeId][adapter][payloadHash];

        require(recovery != 0, RecoveryNotInitiated());
        require(recovery <= block.timestamp, RecoveryChallengePeriodNotEnded());

        delete recoveries[centrifugeId][adapter][payloadHash];
        _handle(centrifugeId, payload, adapter, true);
        emit ExecuteRecovery(centrifugeId, payload, adapter);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageSender
    function send(uint16 centrifugeId, bytes calldata message) external pauseable auth {
        require(message.length > 0, EmptyMessage());

        PoolId poolId = processor.messagePoolId(message);

        emit PrepareMessage(centrifugeId, poolId, message);

        if (isBatching) {
            bytes32 batchSlot = _outboundBatchSlot(centrifugeId, poolId);
            bytes memory previousMessage = TransientBytesLib.get(batchSlot);

            bytes32 gasLimitSlot = _gasLimitSlot(centrifugeId, poolId);
            uint128 newGasLimit = gasLimitSlot.tloadUint128() + gasService.gasLimit(centrifugeId, message);
            require(newGasLimit <= gasService.maxBatchSize(centrifugeId), ExceedsMaxBatchSize());
            gasLimitSlot.tstore(uint256(newGasLimit));

            if (previousMessage.length == 0) {
                TransientArrayLib.push(BATCH_LOCATORS_SLOT, _encodeLocator(centrifugeId, poolId));
            }

            TransientBytesLib.append(batchSlot, message);
        } else {
            _send(centrifugeId, poolId, message);
            _refundTransaction();
        }
    }

    function _send(uint16 centrifugeId, PoolId poolId, bytes memory batch) internal returns (bool succeeded) {
        IAdapter[] memory adapters_ = adapters[centrifugeId];
        require(adapters[centrifugeId].length != 0, EmptyAdapterSet());

        SendData memory data = SendData({
            batchHash: keccak256(batch),
            batchGasLimit: (isBatching)
                ? _gasLimitSlot(centrifugeId, poolId).tloadUint128()
                : gasService.gasLimit(centrifugeId, batch),
            payloadId: bytes32(""),
            gasCost: new uint256[](MAX_ADAPTER_COUNT)
        });
        data.payloadId = keccak256(abi.encodePacked(localCentrifugeId, centrifugeId, data.batchHash));

        // Estimate gas usage
        uint256 total;
        for (uint256 i; i < adapters_.length; i++) {
            data.gasCost[i] = adapters_[i].estimate(
                centrifugeId,
                i == PRIMARY_ADAPTER_ID - 1 ? batch : data.batchHash.serializeMessageProof(),
                data.batchGasLimit
            );

            total += data.gasCost[i];
        }

        // Ensure sufficient funds are available
        if (transactionRefund != address(0)) {
            require(total <= fuel, NotEnoughTransactionGas());
            fuel -= total;
        } else {
            if (total > subsidy[poolId].value) {
                _requestPoolFunding(poolId);
            }

            if (total <= subsidy[poolId].value) {
                subsidy[poolId].value -= uint96(total);
            } else {
                underpaid[centrifugeId][data.batchHash]++;
                emit UnderpaidBatch(centrifugeId, batch);
                return false;
            }
        }

        // Send batch and proofs
        for (uint256 j; j < adapters_.length; j++) {
            bytes32 adapterData = adapters_[j].send{value: data.gasCost[j]}(
                centrifugeId,
                j == PRIMARY_ADAPTER_ID - 1 ? batch : data.batchHash.serializeMessageProof(),
                data.batchGasLimit,
                transactionRefund != address(0) ? transactionRefund : address(subsidy[poolId].refund)
            );

            if (j == PRIMARY_ADAPTER_ID - 1) {
                emit SendBatch(
                    centrifugeId,
                    data.payloadId,
                    batch,
                    adapters_[j],
                    adapterData,
                    transactionRefund != address(0) ? transactionRefund : address(subsidy[poolId].refund)
                );
            } else {
                emit SendProof(
                    centrifugeId,
                    data.payloadId,
                    data.batchHash,
                    adapters_[j],
                    adapterData
                );
            }
        }

        return true;
    }

    /// @inheritdoc IGateway
    function repay(uint16 centrifugeId, bytes memory batch) external payable pauseable {
        bytes32 batchHash = keccak256(batch);
        require(underpaid[centrifugeId][batchHash] > 0, NotUnderpaidBatch());

        PoolId poolId = processor.messagePoolId(batch);
        if (msg.value > 0) subsidizePool(poolId);

        require(_send(centrifugeId, poolId, batch), InsufficientFundsForRepayment());
        underpaid[centrifugeId][batchHash]--;

        emit RepayBatch(centrifugeId, batch);
    }

    function _refundTransaction() internal {
        if (transactionRefund == address(0)) return;

        // Reset before external call
        uint256 fuel_ = fuel;
        address transactionRefund_ = transactionRefund;
        fuel = 0;
        transactionRefund = address(0);

        if (fuel_ > 0) {
            (bool success,) = payable(transactionRefund_).call{value: fuel_}(new bytes(0));

            if (!success) {
                // If refund fails, move remaining fuel to global pot
                _subsidizePool(GLOBAL_POT, transactionRefund_, fuel_);
            }
        }
    }

    function _requestPoolFunding(PoolId poolId) internal {
        IRecoverable refund = subsidy[poolId].refund;
        if (!poolId.isNull() && address(refund) != address(0)) {
            uint256 refundBalance = address(refund).balance;
            if (refundBalance == 0) return;

            // Send to the gateway GLOBAL_POT
            refund.recoverTokens(ETH_ADDRESS, address(this), refundBalance);

            // Extract from the GLOBAL_POT
            subsidy[GLOBAL_POT].value -= uint96(refundBalance);
            _subsidizePool(poolId, address(refund), refundBalance);
        }
    }

    /// @inheritdoc IGateway
    function setRefundAddress(PoolId poolId, IRecoverable refund) public auth {
        subsidy[poolId].refund = refund;
        emit SetRefundAddress(poolId, refund);
    }

    /// @inheritdoc IGateway
    function subsidizePool(PoolId poolId) public payable {
        require(address(subsidy[poolId].refund) != address(0), RefundAddressNotSet());
        _subsidizePool(poolId, msg.sender, msg.value);
    }

    function _subsidizePool(PoolId poolId, address who, uint256 value) internal {
        subsidy[poolId].value += uint96(value);
        emit SubsidizePool(poolId, who, value);
    }

    /// @inheritdoc IGateway
    function payTransaction(address payer) external payable auth {
        transactionRefund = payer;
        fuel += msg.value;
    }

    /// @inheritdoc IGateway
    function startBatching() external auth {
        isBatching = true;
    }

    /// @inheritdoc IGateway
    function endBatching() external auth {
        require(isBatching, NoBatched());

        bytes32[] memory locators = TransientArrayLib.getBytes32(BATCH_LOCATORS_SLOT);
        for (uint256 i; i < locators.length; i++) {
            (uint16 centrifugeId, PoolId poolId) = _parseLocator(locators[i]);
            bytes32 outboundBatchSlot = _outboundBatchSlot(centrifugeId, poolId);

            _send(centrifugeId, poolId, TransientBytesLib.get(outboundBatchSlot));

            TransientBytesLib.clear(outboundBatchSlot);
            _gasLimitSlot(centrifugeId, poolId).tstore(uint256(0));
        }

        TransientArrayLib.clear(BATCH_LOCATORS_SLOT);
        isBatching = false;

        _refundTransaction();
    }

    function _encodeLocator(uint16 centrifugeId, PoolId poolId) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(bytes2(centrifugeId), bytes8(poolId.raw())));
    }

    function _parseLocator(bytes32 locator) internal pure returns (uint16 centrifugeId, PoolId poolId) {
        centrifugeId = uint16(bytes2(locator));
        poolId = PoolId.wrap(uint64(bytes8(locator << 16)));
    }

    function _gasLimitSlot(uint16 centrifugeId, PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode("batchGasLimit", centrifugeId, poolId));
    }

    function _outboundBatchSlot(uint16 centrifugeId, PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode("outboundBatch", centrifugeId, poolId));
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IGateway
    function estimate(uint16 centrifugeId, bytes calldata payload) external view returns (uint256 total) {
        bytes memory proof = keccak256(payload).serializeMessageProof();

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

