// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {ArrayLib} from "src/misc/libraries/ArrayLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";

import {IGateway, IMessageHandler} from "src/vaults/interfaces/gateway/IGateway.sol";
import {IRoot} from "src/vaults/interfaces/IRoot.sol";
import {IGasService} from "src/vaults/interfaces/gateway/IGasService.sol";
import {IAdapter} from "src/vaults/interfaces/gateway/IAdapter.sol";
import {IRecoverable} from "src/vaults/interfaces/IRoot.sol";

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

    IRoot public immutable root;

    address public poolManager;
    address public investmentManager;
    IGasService public gasService;

    mapping(bytes32 messageHash => Message) internal _messages;
    mapping(address adapter => Adapter) internal _activeAdapters;

    /// @inheritdoc IGateway
    address[] public adapters;
    /// @inheritdoc IGateway
    mapping(address payer => bool) public payers;
    /// @inheritdoc IGateway
    mapping(uint8 messageId => address) public messageHandlers;
    /// @inheritdoc IGateway
    mapping(address adapter => mapping(bytes32 messageHash => uint256 timestamp)) public recoveries;

    constructor(address root_, address poolManager_, address investmentManager_, address gasService_)
        Auth(msg.sender)
    {
        root = IRoot(root_);
        poolManager = poolManager_;
        investmentManager = investmentManager_;
        gasService = IGasService(gasService_);
    }

    modifier pauseable() {
        require(!root.paused(), "Gateway/paused");
        _;
    }

    receive() external payable {
        emit ReceiveNativeTokens(msg.sender, msg.value);
    }

    // --- Administration ---
    /// @inheritdoc IGateway
    function file(bytes32 what, address[] calldata addresses) external auth {
        if (what == "adapters") {
            uint8 quorum_ = addresses.length.toUint8();
            require(quorum_ != 0, "Gateway/empty-adapter-set");
            require(quorum_ <= MAX_ADAPTER_COUNT, "Gateway/exceeds-max");

            // Increment session id to reset pending votes
            uint256 numAdapters = adapters.length;
            uint64 sessionId = numAdapters > 0 ? _activeAdapters[adapters[0]].activeSessionId + 1 : 0;

            // Disable old adapters
            for (uint8 i; i < numAdapters; i++) {
                delete _activeAdapters[adapters[i]];
            }

            // Enable new adapters, setting quorum to number of adapters
            for (uint8 j; j < quorum_; j++) {
                require(_activeAdapters[addresses[j]].id == 0, "Gateway/no-duplicates-allowed");

                // Ids are assigned sequentially starting at 1
                _activeAdapters[addresses[j]] = Adapter(j + 1, quorum_, sessionId);
            }

            adapters = addresses;
        } else {
            revert("Gateway/file-unrecognized-param");
        }

        emit File(what, addresses);
    }

    /// @inheritdoc IGateway
    function file(bytes32 what, address instance) external auth {
        if (what == "gasService") gasService = IGasService(instance);
        else if (what == "investmentManager") investmentManager = instance;
        else if (what == "poolManager") poolManager = instance;
        else revert("Gateway/file-unrecognized-param");

        emit File(what, instance);
    }

    /// @inheritdoc IGateway
    function file(bytes32 what, uint8 data1, address data2) public auth {
        if (what == "message") {
            require(data1 > uint8(type(MessageType).max), "Gateway/hardcoded-message-id");
            messageHandlers[data1] = data2;
        } else {
            revert("Gateway/file-unrecognized-param");
        }
        emit File(what, data1, data2);
    }

    /// @inheritdoc IGateway
    function file(bytes32 what, address payer, bool isAllowed) external auth {
        if (what == "payers") payers[payer] = isAllowed;
        else revert("Gateway/file-unrecognized-param");

        emit File(what, payer, isAllowed);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, address receiver, uint256 amount) external auth {
        if (token == address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) {
            SafeTransferLib.safeTransferETH(receiver, amount);
        } else {
            SafeTransferLib.safeTransfer(token, receiver, amount);
        }
    }

    // --- Incoming ---
    /// @inheritdoc IGateway
    function handle(bytes calldata message) external pauseable {
        _handle(message, msg.sender, false);
    }

    function _handle(bytes calldata payload, address adapter_, bool isRecovery) internal {
        Adapter memory adapter = _activeAdapters[adapter_];
        require(adapter.id != 0, "Gateway/invalid-adapter");
        uint8 code = payload.messageCode();
        if (
            code == uint8(MessageType.InitiateMessageRecovery)
                || code == uint8(MessageType.DisputeMessageRecovery)
        ) {
            require(!isRecovery, "Gateway/no-recursion");
            require(adapters.length > 1, "Gateway/no-recovery-with-one-adapter-allowed");
            return _handleRecovery(payload);
        }

        bool isMessageProof = code == uint8(MessageType.MessageProof);
        if (adapter.quorum == 1 && !isMessageProof) {
            // Special case for gas efficiency
            _dispatch(payload, false);
            emit ExecuteMessage(payload, adapter_);
            return;
        }

        // Verify adapter and parse message hash
        bytes32 messageHash;
        if (isMessageProof) {
            require(isRecovery || adapter.id != PRIMARY_ADAPTER_ID, "Gateway/non-proof-adapter");
            messageHash = payload.deserializeMessageProof().hash;
            emit ProcessProof(messageHash, adapter_);
        } else {
            require(isRecovery || adapter.id == PRIMARY_ADAPTER_ID, "Gateway/non-message-adapter");
            messageHash = keccak256(payload);
            emit ProcessMessage(payload, adapter_);
        }

        Message storage state = _messages[messageHash];

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
                _dispatch(state.pendingMessage, false);
                emit ExecuteMessage(state.pendingMessage, adapter_);
            } else {
                _dispatch(payload, false);
                emit ExecuteMessage(payload, adapter_);
            }

            // Only if there are no more pending messages, remove the pending message
            if (state.votes.isEmpty()) {
                delete state.pendingMessage;
            }
        } else if (!isMessageProof) {
            state.pendingMessage = payload;
        }
    }

    function _dispatch(bytes memory message, bool isBatched) internal {
        uint8 id = message.toUint8(0);
        address manager;

        if (id == 4) {
            // Handle batch messages
            require(!isBatched, "Gateway/no-recursive-batching-allowed");
            uint256 offset = 1; // Offsets the message type which is 1 byte
            uint256 messageLength = message.length;

            // Check if the message actually contains 2 bytes dedicated for the subMessage length
            while (offset + 2 <= messageLength) {
                uint16 subMessageLength = message.toUint16(offset);
                bytes memory subMessage = new bytes(subMessageLength);
                offset = offset + 2; // Skip subMessage length

                require(offset + subMessageLength <= messageLength, "Gateway/corrupted-message");
                for (uint256 i; i < subMessageLength; i++) {
                    subMessage[i] = message[offset + i];
                }
                _dispatch(subMessage, true);

                offset += subMessageLength;
            }
            return;
        } else if (id >= 5 && id <= 7) {
            manager = address(root);
        } else if (id == 8) {
            manager = address(gasService);
        } else if (id >= 9 && id <= 18) {
            manager = poolManager;
        } else if (id >= 19 && id <= 27) {
            manager = investmentManager;
        } else {
            // Dynamic path for other managers, to be able to easily
            // extend functionality of Liquidity Pools
            manager = messageHandlers[id];
            require(manager != address(0), "Gateway/unregistered-message-id");
        }

        IMessageHandler(manager).handle(message);
    }

    function _handleRecovery(bytes memory message) internal {
        MessageType kind = message.messageType();

        if (kind == MessageType.InitiateMessageRecovery) {
            MessageLib.InitiateMessageRecovery memory m = message.deserializeInitiateMessageRecovery();
            address adapter = address(bytes20(m.adapter));
            require(_activeAdapters[adapter].id != 0, "Gateway/invalid-adapter");
            recoveries[adapter][m.hash] = block.timestamp + RECOVERY_CHALLENGE_PERIOD;
            emit InitiateMessageRecovery(m.hash, adapter);
        }
        else if (kind == MessageType.DisputeMessageRecovery) {
            MessageLib.DisputeMessageRecovery memory m = message.deserializeDisputeMessageRecovery();
            return _disputeMessageRecovery(address(bytes20(m.adapter)), m.hash);
        }
    }

    /// @inheritdoc IGateway
    function disputeMessageRecovery(address adapter, bytes32 messageHash) external auth {
        _disputeMessageRecovery(adapter, messageHash);
    }

    function _disputeMessageRecovery(address adapter, bytes32 messageHash) internal {
        delete recoveries[adapter][messageHash];
        emit DisputeMessageRecovery(messageHash, adapter);
    }

    /// @inheritdoc IGateway
    function executeMessageRecovery(address adapter, bytes calldata message) external {
        bytes32 messageHash = keccak256(message);
        uint256 recovery = recoveries[adapter][messageHash];

        require(recovery != 0, "Gateway/message-recovery-not-initiated");
        require(recovery <= block.timestamp, "Gateway/challenge-period-has-not-ended");

        delete recoveries[adapter][messageHash];
        _handle(message, adapter, true);
        emit ExecuteMessageRecovery(message, adapter);
    }

    // --- Outgoing ---
    /// @inheritdoc IGateway
    function send(uint32 /*chainId*/, bytes calldata message, address source) public payable pauseable {
        bool isManager = msg.sender == investmentManager || msg.sender == poolManager;
        require(isManager || msg.sender == messageHandlers[message.toUint8(0)], "Gateway/invalid-manager");

        bytes memory proof = MessageLib.MessageProof({hash: keccak256(message)}).serialize();

        uint256 numAdapters = adapters.length;
        require(numAdapters != 0, "Gateway/not-initialized");

        uint256 messageCost = gasService.estimate(message);
        uint256 proofCost = gasService.estimate(proof);

        if (fuel != 0) {
            uint256 tank = fuel;
            for (uint256 i; i < numAdapters; i++) {
                IAdapter currentAdapter = IAdapter(adapters[i]);
                bool isPrimaryAdapter = i == PRIMARY_ADAPTER_ID - 1;
                bytes memory payload = isPrimaryAdapter ? message : proof;

                uint256 consumed = currentAdapter.estimate(payload, isPrimaryAdapter ? messageCost : proofCost);

                require(consumed <= tank, "Gateway/not-enough-gas-funds");
                tank -= consumed;

                currentAdapter.pay{value: consumed}(payload, address(this));

                currentAdapter.send(payload);
            }
            fuel = 0;
        } else if (gasService.shouldRefuel(source, message)) {
            for (uint256 i; i < numAdapters; i++) {
                IAdapter currentAdapter = IAdapter(adapters[i]);
                bool isPrimaryAdapter = i == PRIMARY_ADAPTER_ID - 1;
                bytes memory payload = isPrimaryAdapter ? message : proof;

                uint256 consumed = currentAdapter.estimate(payload, isPrimaryAdapter ? messageCost : proofCost);

                if (consumed <= address(this).balance) {
                    currentAdapter.pay{value: consumed}(payload, address(this));
                }

                currentAdapter.send(payload);
            }
        } else {
            revert("Gateway/not-enough-gas-funds");
        }

        emit SendMessage(message);
    }

    /// @inheritdoc IGateway
    function topUp() external payable {
        require(payers[msg.sender], "Gateway/only-payers-can-top-up");
        require(msg.value != 0, "Gateway/cannot-topup-with-nothing");
        fuel = msg.value;
    }

    // --- Helpers ---
    /// @inheritdoc IGateway
    function estimate(bytes calldata payload) external view returns (uint256[] memory perAdapter, uint256 total) {
        bytes memory proof = MessageLib.MessageProof({hash: keccak256(payload)}).serialize();
        uint256 messageCost = gasService.estimate(payload);
        uint256 proofCost = gasService.estimate(proof);
        perAdapter = new uint256[](adapters.length);

        uint256 adaptersCount = adapters.length;
        for (uint256 i; i < adaptersCount; i++) {
            uint256 centrifugeCost = i == PRIMARY_ADAPTER_ID - 1 ? messageCost : proofCost;
            bytes memory message = i == PRIMARY_ADAPTER_ID - 1 ? payload : proof;
            uint256 estimated = IAdapter(adapters[i]).estimate(message, centrifugeCost);
            perAdapter[i] = estimated;
            total += estimated;
        }
    }

    /// @inheritdoc IGateway
    function quorum() external view returns (uint8) {
        Adapter memory adapter = _activeAdapters[adapters[0]];
        return adapter.quorum;
    }

    /// @inheritdoc IGateway
    function activeSessionId() external view returns (uint64) {
        Adapter memory adapter = _activeAdapters[adapters[0]];
        return adapter.activeSessionId;
    }

    /// @inheritdoc IGateway
    function votes(bytes32 messageHash) external view returns (uint16[MAX_ADAPTER_COUNT] memory) {
        return _messages[messageHash].votes;
    }
}
