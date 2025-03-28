// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {ArrayLib} from "src/misc/libraries/ArrayLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";

import {MessageType, MessageCategory, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IRoot, IRecoverable} from "src/common/interfaces/IRoot.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {PoolId} from "src/common/types/PoolId.sol";

/// @title  Gateway
/// @notice Routing contract that forwards outgoing messages to multiple adapters (1 full message, n-1 proofs)
///         and validates that multiple adapters have confirmed a message.
///         Handling incoming messages from the Centrifuge Chain through multiple adapters.
///         Supports processing multiple duplicate messages in parallel by
///         storing counts of messages and proofs that have been received.
contract Gateway is Auth, IGateway, IRecoverable {
    using ArrayLib for uint16[8];
    using BytesLib for bytes;
    using MessageLib for *;
    using MathLib for uint256;

    uint8 public constant MAX_ADAPTER_COUNT = 8;
    uint8 public constant PRIMARY_ADAPTER_ID = 1;
    uint256 public constant RECOVERY_CHALLENGE_PERIOD = 7 days;

    uint256 public transient fuel;

    /// @dev Says if a send() was performed, but it's still pending to finalize the batch
    bool public transient pendingBatch;

    /// @notice Tells is the gateway is actually configured to create batches
    bool public transient isBatching;

    /// @notice The payer of the transaction.
    /// @dev This is never used along with batching
    address public transient payableSource;

    /// @notice The pool associated to the message.
    /// @dev This is never used along with batching
    PoolId public transient payablePool;

    IRoot public immutable root;
    IGasService public gasService;

    IMessageHandler public handler;

    mapping(uint16 chainId => mapping(bytes32 messageHash => Message)) internal _messages;
    mapping(uint16 chainId => mapping(IAdapter adapter => Adapter)) internal _activeAdapters;

    /// @notice Amount of native tokens received per pool for paying messages
    mapping(PoolId => uint256) public subsidy;

    /// @inheritdoc IGateway
    mapping(uint16 chainId => IAdapter[]) public adapters;

    /// @inheritdoc IGateway
    mapping(uint16 chainId => mapping(IAdapter adapter => mapping(bytes32 messageHash => uint256 timestamp))) public recoveries;

    /// @notice Current batch messages pending to be sent
    mapping(uint16 chainId => bytes) public /*transient*/ batch;

    /// @notice Chains ID with pending batch messages
    uint16[] public /*transient*/ chainIds;

    constructor(IRoot root_, IGasService gasService_) Auth(msg.sender) {
        root = root_;
        gasService = gasService_;
    }

    modifier pauseable() {
        require(!root.paused(), "Gateway/paused");
        _;
    }

    function subsidizePool(PoolId poolId) external payable {
        subsidy[poolId] += msg.value;
        emit ReceiveNativeTokens(poolId, msg.sender, msg.value);
    }

    //----------------------------------------------------------------------------------------------
    // Administration methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IGateway
    function file(bytes32 what, uint16 chainId, IAdapter[] calldata addresses) external auth {
        if (what == "adapters") {
            uint8 quorum_ = addresses.length.toUint8();
            require(quorum_ != 0, "Gateway/empty-adapter-set");
            require(quorum_ <= MAX_ADAPTER_COUNT, "Gateway/exceeds-max");

            // Increment session id to reset pending votes
            uint256 numAdapters = adapters[chainId].length;
            uint64 sessionId = numAdapters > 0 ? _activeAdapters[chainId][adapters[chainId][0]].activeSessionId + 1 : 0;

            // Disable old adapters
            for (uint8 i; i < numAdapters; i++) {
                delete _activeAdapters[chainId][adapters[chainId][i]];
            }

            // Enable new adapters, setting quorum to number of adapters
            for (uint8 j; j < quorum_; j++) {
                require(_activeAdapters[chainId][addresses[j]].id == 0, "Gateway/no-duplicates-allowed");

                // Ids are assigned sequentially starting at 1
                _activeAdapters[chainId][addresses[j]] = Adapter(j + 1, quorum_, sessionId);
            }

            adapters[chainId] = addresses;
        } else {
            revert("Gateway/file-unrecognized-param");
        }

        emit File(what, chainId, addresses);
    }

    /// @inheritdoc IGateway
    function file(bytes32 what, address instance) external auth {
        if (what == "gasService") gasService = IGasService(instance);
        else if (what == "handler") handler = IMessageHandler(instance);
        else revert("Gateway/file-unrecognized-param");

        emit File(what, instance);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, uint256 tokenId, address receiver, uint256 amount) external auth {
        if (token == address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) {
            SafeTransferLib.safeTransferETH(receiver, amount);
        } else if (tokenId == 0) {
            SafeTransferLib.safeTransfer(token, receiver, amount);
        } else {
            IERC6909(token).transfer(receiver, tokenId, amount);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Incoming methods
    //----------------------------------------------------------------------------------------------

    /// @dev Handle a batch of messages
    function handle(uint16 chainId, bytes memory message) external pauseable {
        while (message.length > 0) {
            _handle(chainId, message, IAdapter(msg.sender), false);

            uint16 messageLength = message.messageLength();

            // TODO: optimize with assembly to just shift the pointer in the array
            // TODO: Could we use `calldata` message in the signature? Highly desired to avoid a copy.
            message = message.slice(messageLength, message.length - messageLength);
        }
    }

    /// @dev Handle an isolated message
    function _handle(uint16 chainId, bytes memory payload, IAdapter adapter_, bool isRecovery) internal {
        Adapter memory adapter = _activeAdapters[chainId][adapter_];
        require(adapter.id != 0, "Gateway/invalid-adapter");

        uint8 code = payload.messageCode();
        if (code == uint8(MessageType.InitiateMessageRecovery) || code == uint8(MessageType.DisputeMessageRecovery)) {
            require(!isRecovery, "Gateway/no-recursion");
            require(adapters[chainId].length > 1, "Gateway/no-recovery-with-one-adapter-allowed");
            return _handleRecovery(chainId, payload);
        }

        bool isMessageProof = code == uint8(MessageType.MessageProof);
        if (adapter.quorum == 1 && !isMessageProof) {
            // Special case for gas efficiency
            handler.handle(chainId, payload);
            emit ExecuteMessage(chainId, payload, adapter_);
            return;
        }

        // Verify adapter and parse message hash
        bytes32 messageHash;
        if (isMessageProof) {
            require(isRecovery || adapter.id != PRIMARY_ADAPTER_ID, "Gateway/non-proof-adapter");
            messageHash = payload.deserializeMessageProof().hash;
            emit ProcessProof(chainId, messageHash, adapter_);
        } else {
            require(isRecovery || adapter.id == PRIMARY_ADAPTER_ID, "Gateway/non-message-adapter");
            messageHash = keccak256(payload);
            emit ProcessMessage(chainId, payload, adapter_);
        }

        Message storage state = _messages[chainId][messageHash];

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
                handler.handle(chainId, state.pendingMessage);
                emit ExecuteMessage(chainId, state.pendingMessage, adapter_);
            } else {
                handler.handle(chainId, payload);
                emit ExecuteMessage(chainId, payload, adapter_);
            }

            // Only if there are no more pending messages, remove the pending message
            if (state.votes.isEmpty()) {
                delete state.pendingMessage;
            }
        } else if (!isMessageProof) {
            state.pendingMessage = payload;
        }
    }

    function _handleRecovery(uint16 chainId, bytes memory message) internal {
        MessageType kind = message.messageType();

        if (kind == MessageType.InitiateMessageRecovery) {
            MessageLib.InitiateMessageRecovery memory m = message.deserializeInitiateMessageRecovery();
            IAdapter adapter = IAdapter(address(bytes20(m.adapter)));
            require(_activeAdapters[chainId][adapter].id != 0, "Gateway/invalid-adapter");
            recoveries[chainId][adapter][m.hash] = block.timestamp + RECOVERY_CHALLENGE_PERIOD;
            emit InitiateMessageRecovery(chainId, m.hash, adapter);
        } else if (kind == MessageType.DisputeMessageRecovery) {
            MessageLib.DisputeMessageRecovery memory m = message.deserializeDisputeMessageRecovery();
            return _disputeMessageRecovery(chainId, IAdapter(address(bytes20(m.adapter))), m.hash);
        }
    }

    /// @inheritdoc IGateway
    function disputeMessageRecovery(uint16 chainId, IAdapter adapter, bytes32 messageHash) external auth {
        _disputeMessageRecovery(chainId, adapter, messageHash);
    }

    function _disputeMessageRecovery(uint16 chainId, IAdapter adapter, bytes32 messageHash) internal {
        delete recoveries[chainId][adapter][messageHash];
        emit DisputeMessageRecovery(chainId, messageHash, adapter);
    }

    /// @inheritdoc IGateway
    function executeMessageRecovery(uint16 chainId, IAdapter adapter, bytes calldata message) external {
        bytes32 messageHash = keccak256(message);
        uint256 recovery = recoveries[chainId][adapter][messageHash];

        require(recovery != 0, "Gateway/message-recovery-not-initiated");
        require(recovery <= block.timestamp, "Gateway/challenge-period-has-not-ended");

        delete recoveries[chainId][adapter][messageHash];
        _handle(chainId, message, adapter, true);
        emit ExecuteMessageRecovery(chainId, message, adapter);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageSender
    function send(uint16 chainId, bytes calldata message) external pauseable auth {
        emit Log(chainId);
        if (isBatching) {
            pendingBatch = true;

            bytes storage previousMessage = batch[chainId];
            if (previousMessage.length == 0) {
                chainIds.push(chainId);
                batch[chainId] = message;
            } else {
                batch[chainId] = bytes.concat(previousMessage, message);
            }
        } else {
            _send(chainId, message);
        }
    }

    function _send(uint16 chainId, bytes memory message) private {
        bytes memory proof = MessageLib.MessageProof({hash: keccak256(message)}).serialize();

        IAdapter[] memory adapters_ = adapters[chainId];
        require(adapters[chainId].length != 0, "Gateway/not-initialized");

        uint256 messageGasLimit = gasService.estimate(chainId, message);
        uint256 proofGasLimit = gasService.estimate(chainId, proof);

        if (fuel != 0) {
            uint256 tank = fuel;
            for (uint256 i; i < adapters_.length; i++) {
                IAdapter currentAdapter = IAdapter(adapters_[i]);
                bool isPrimaryAdapter = i == PRIMARY_ADAPTER_ID - 1;
                bytes memory payload = isPrimaryAdapter ? message : proof;

                uint256 consumed =
                    currentAdapter.estimate(chainId, payload, isPrimaryAdapter ? messageGasLimit : proofGasLimit);

                require(consumed <= tank, "Gateway/not-enough-gas-funds");
                tank -= consumed;

                currentAdapter.send{value: consumed}(
                    chainId, payload, isPrimaryAdapter ? messageGasLimit : proofGasLimit, address(this)
                );
            }
            fuel = 0;
        } else if (gasService.shouldRefuel(payableSource, payablePool, message)) {
            for (uint256 i; i < adapters_.length; i++) {
                IAdapter currentAdapter = IAdapter(adapters_[i]);
                bool isPrimaryAdapter = i == PRIMARY_ADAPTER_ID - 1;
                bytes memory payload = isPrimaryAdapter ? message : proof;

                uint256 consumed =
                    currentAdapter.estimate(chainId, payload, isPrimaryAdapter ? messageGasLimit : proofGasLimit);

                if (consumed <= subsidy[payablePool]) {
                    currentAdapter.send{value: consumed}(
                        chainId, payload, isPrimaryAdapter ? messageGasLimit : proofGasLimit, address(this)
                    );
                    subsidy[payablePool] -= consumed;
                } else {
                    currentAdapter.send(
                        chainId, payload, isPrimaryAdapter ? messageGasLimit : proofGasLimit, address(this)
                    );
                }
            }
        } else {
            revert("Gateway/not-enough-gas-funds");
        }

        emit SendMessage(message);
    }

    /// @inheritdoc IGateway
    function topUp() external payable {
        // We only require the top up if:
        // - We're not in a multicall.
        // - Or we're in a multicall, but at least one message is required to be sent
        if (!isBatching || pendingBatch) {
            require(msg.value != 0, "Gateway/cannot-topup-with-nothing");
            fuel = msg.value;
        }
    }

    /// @inheritdoc IGateway
    function setPayableSource(address source, PoolId poolId) external {
        payableSource = source;
        payablePool = poolId;
    }

    /// @inheritdoc IGateway
    function startBatch() external {
        isBatching = true;
    }

    event Log(uint16 destCHain);

    /// @inheritdoc IGateway
    function endBatch() external {
        require(isBatching, NoBatched());

        for (uint256 i; i < chainIds.length; i++) {
            uint16 chainId = chainIds[i];
            emit Log(chainId);
            _send(chainId, batch[chainId]);
            delete batch[chainId];
        }

        delete chainIds;
        pendingBatch = false;
        isBatching = false;
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IGateway
    function estimate(uint16 chainId, bytes calldata payload)
        external
        view
        returns (uint256[] memory perAdapter, uint256 total)
    {
        bytes memory proof = MessageLib.MessageProof({hash: keccak256(payload)}).serialize();
        uint256 messageGasLimit = gasService.estimate(chainId, payload);
        uint256 proofGasLimit = gasService.estimate(chainId, proof);
        perAdapter = new uint256[](adapters[chainId].length);

        uint256 adaptersCount = adapters[chainId].length;
        for (uint256 i; i < adaptersCount; i++) {
            uint256 gasLimit = i == PRIMARY_ADAPTER_ID - 1 ? messageGasLimit : proofGasLimit;
            bytes memory message = i == PRIMARY_ADAPTER_ID - 1 ? payload : proof;
            uint256 estimated = IAdapter(adapters[chainId][i]).estimate(chainId, message, gasLimit);
            perAdapter[i] = estimated;
            total += estimated;
        }
    }

    /// @inheritdoc IGateway
    function quorum(uint16 chainId) external view returns (uint8) {
        Adapter memory adapter = _activeAdapters[chainId][adapters[chainId][0]];
        return adapter.quorum;
    }

    /// @inheritdoc IGateway
    function activeSessionId(uint16 chainId) external view returns (uint64) {
        Adapter memory adapter = _activeAdapters[chainId][adapters[chainId][0]];
        return adapter.activeSessionId;
    }

    /// @inheritdoc IGateway
    function votes(uint16 chainId, bytes32 messageHash) external view returns (uint16[MAX_ADAPTER_COUNT] memory) {
        return _messages[chainId][messageHash].votes;
    }

    /// @inheritdoc IGateway
    function adapterCount(uint16 chainId) external view returns (uint256) {
        return adapters[chainId].length;
    }
}
