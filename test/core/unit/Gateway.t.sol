// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/Auth.sol";
import {BytesLib} from "../../../src/misc/libraries/BytesLib.sol";
import {TransientArrayLib} from "../../../src/misc/libraries/TransientArrayLib.sol";
import {TransientBytesLib} from "../../../src/misc/libraries/TransientBytesLib.sol";
import {TransientStorageLib} from "../../../src/misc/libraries/TransientStorageLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {Gateway} from "../../../src/core/messaging/Gateway.sol";
import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IProtocolPauser} from "../../../src/core/messaging/interfaces/IProtocolPauser.sol";
import {IMessageProperties} from "../../../src/core/messaging/interfaces/IMessageProperties.sol";
import {
    IGateway,
    PROCESS_FAIL_MESSAGE_GAS,
    MESSAGE_MAX_LENGTH,
    ERR_MAX_LENGTH
} from "../../../src/core/messaging/interfaces/IGateway.sol";

import {IRoot} from "../../../src/admin/interfaces/IRoot.sol";

import "forge-std/Test.sol";

// -----------------------------------------
//     MESSAGE MOCKING
// -----------------------------------------

PoolId constant POOL_A = PoolId.wrap(23);
PoolId constant POOL_0 = PoolId.wrap(0);
uint16 constant REMOTE_CENT_ID = 24;
uint16 constant LOCAL_CENT_ID = 23;

uint128 constant MAX_BATCH_GAS_LIMIT = 1_000_000;
uint128 constant BASE_COST = 50_000;
uint128 constant MESSAGE_PROCESSING_GAS_LIMIT = 100_000 + uint128(PROCESS_FAIL_MESSAGE_GAS);
uint128 constant MESSAGE_OVERALL_GAS_LIMIT = BASE_COST + MESSAGE_PROCESSING_GAS_LIMIT;
uint128 constant EXTRA_GAS_LIMIT = 200_000;

enum MessageKind {
    _Invalid,
    _MessageProof,
    WithPool0,
    WithPoolA1,
    WithPoolA1ExtraGas,
    WithPoolA1TooMuchGas,
    WithPoolA2,
    WithPoolAFail, // Use this will fail
    WithPoolALongFail, // Use this will fail
    WithPoolATooLong
}

function length(MessageKind kind) pure returns (uint16) {
    if (kind == MessageKind.WithPool0) return 5;
    if (kind == MessageKind.WithPoolA1) return 10;
    if (kind == MessageKind.WithPoolA1ExtraGas) return 10;
    if (kind == MessageKind.WithPoolA1TooMuchGas) return 10;
    if (kind == MessageKind.WithPoolA2) return 15;
    if (kind == MessageKind.WithPoolAFail) return 10;
    if (kind == MessageKind.WithPoolALongFail) return uint16(10);
    if (kind == MessageKind.WithPoolATooLong) return uint16(MESSAGE_MAX_LENGTH + 1);
    return 2;
}

function asBytes(MessageKind kind) pure returns (bytes memory) {
    bytes memory encoded = new bytes(length(kind));
    encoded[0] = bytes1(uint8(kind));
    return encoded;
}

using {asBytes, length} for MessageKind;

// A MessageLib agnostic processor
contract MockProcessor {
    using BytesLib for bytes;

    error HandleError();

    mapping(uint16 => bytes[]) public processed;
    bool shouldNotFail;
    IMessageProperties properties;

    constructor(IMessageProperties properties_) {
        properties = properties_;
    }

    function disableFailure() public {
        shouldNotFail = true;
    }

    function handle(uint16 centrifugeId, bytes memory payload) external {
        if (payload.toUint8(0) == uint8(MessageKind.WithPoolALongFail) && !shouldNotFail) {
            revert(new string(ERR_MAX_LENGTH + 1)); // The err will be clamped
        }

        if (payload.toUint8(0) == uint8(MessageKind.WithPoolAFail) && !shouldNotFail) {
            revert HandleError();
        }

        if (!shouldNotFail) {
            // bypass this check for the retry case where all available gas is passed
            require(
                gasleft()
                    <= (properties.messageProcessingGasLimit(centrifugeId, payload) - PROCESS_FAIL_MESSAGE_GAS) * 63
                        / 64,
                "Too much gas passed to handle"
            );
        }
        processed[centrifugeId].push(payload);
    }

    function count(uint16 centrifugeId) external view returns (uint256) {
        return processed[centrifugeId].length;
    }
}

contract MockMessageProperties is IMessageProperties {
    using BytesLib for bytes;

    function messageLength(bytes calldata message) external pure returns (uint16) {
        return MessageKind(message.toUint8(0)).length();
    }

    function messagePoolId(bytes calldata message) external pure returns (PoolId) {
        if (message.toUint8(0) == uint8(MessageKind.WithPool0)) return POOL_0;
        if (message.toUint8(0) == uint8(MessageKind.WithPoolA1)) return POOL_A;
        if (message.toUint8(0) == uint8(MessageKind.WithPoolA1ExtraGas)) return POOL_A;
        if (message.toUint8(0) == uint8(MessageKind.WithPoolA1TooMuchGas)) return POOL_A;
        if (message.toUint8(0) == uint8(MessageKind.WithPoolA2)) return POOL_A;
        if (message.toUint8(0) == uint8(MessageKind.WithPoolAFail)) return POOL_A;
        if (message.toUint8(0) == uint8(MessageKind.WithPoolALongFail)) return POOL_A;
        if (message.toUint8(0) == uint8(MessageKind.WithPoolATooLong)) return POOL_A;
        revert("Unreachable: message never asked for pool");
    }

    function messageOverallGasLimit(uint16 centrifugeId, bytes calldata message) external pure returns (uint128) {
        return messageProcessingGasLimit(centrifugeId, message) + BASE_COST;
    }

    function messageProcessingGasLimit(uint16, bytes memory message) public pure returns (uint128 gasLimit) {
        gasLimit = MESSAGE_PROCESSING_GAS_LIMIT;

        if (message.toUint8(0) == uint8(MessageKind.WithPoolA1ExtraGas)) gasLimit += EXTRA_GAS_LIMIT;
        if (message.toUint8(0) == uint8(MessageKind.WithPoolA1TooMuchGas)) gasLimit += MAX_BATCH_GAS_LIMIT;
    }

    function maxBatchGasLimit(uint16) external pure returns (uint128) {
        return MAX_BATCH_GAS_LIMIT;
    }
}

contract NoPayableDestination {}

// -----------------------------------------
//     GATEWAY EXTENSION
// -----------------------------------------

contract GatewayExt is Gateway, Test {
    using BytesLib for bytes;

    constructor(uint16 localCentrifugeId, IRoot root_, address deployer) Gateway(localCentrifugeId, root_, deployer) {}

    function batchLocatorsLength() public view returns (uint256) {
        return TransientArrayLib.length(BATCH_LOCATORS_SLOT);
    }

    function batchGasLimit(uint16 centrifugeId, PoolId poolId) public view returns (uint128) {
        return TransientStorageLib.tloadUint128(_gasLimitSlot(centrifugeId, poolId));
    }

    function batchLocators(uint256 index) public view returns (uint16 centrifugeId, PoolId poolId) {
        return _parseLocator(TransientArrayLib.getBytes32(BATCH_LOCATORS_SLOT)[index]);
    }

    function outboundBatch(uint16 centrifugeId, PoolId poolId) public view returns (bytes memory) {
        return TransientBytesLib.get(_outboundBatchSlot(centrifugeId, poolId));
    }

    function safeProcess(uint16 centrifugeId, bytes memory message, bytes32 messageHash, uint128 gasLimit) public {
        uint256 prevGas = gasleft();
        // NOTE: we're measuring the whole safeProcess despite only the failed branch should be cover
        // by PROCESS_FAIL_MESSAGE_GAS. We don't have a way to just measure the failed part because
        // reverting and copying values to the callee needs to be consumed by the reserved PROCESS_FAIL_MESSAGE_GAS gas.
        _safeProcess(centrifugeId, message, messageHash, gasLimit);
        uint256 consumedGas = prevGas - gasleft();

        if (
            message.toUint8(0) == uint8(MessageKind.WithPoolAFail)
                || message.toUint8(0) == uint8(MessageKind.WithPoolALongFail)
        ) {
            console.log("stricted consumed gas in the failure:", consumedGas);
            assertLt(consumedGas, PROCESS_FAIL_MESSAGE_GAS, "PROCESS_FAIL_MESSAGE_GAS is not high enough");
        }
    }

    function startBatching() public {
        isBatching = true;
    }

    function endBatching(address refund) public payable {
        _endBatching(msg.value, refund);
    }

    function batcher() public view returns (address) {
        return _batcher;
    }
}

// -----------------------------------------
//     GATEWAY TESTS
// -----------------------------------------

contract GatewayTest is Test {
    uint256 constant ADAPTER_ESTIMATE = 1;
    bytes32 constant ADAPTER_DATA = bytes32("adapter data");

    bool constant NO_SUBSIDIZED = false;

    IRoot root = IRoot(makeAddr("Root"));
    IAdapter adapter = IAdapter(makeAddr("Adapter"));

    MockMessageProperties messageProperties = new MockMessageProperties();
    MockProcessor processor = new MockProcessor(messageProperties);
    GatewayExt gateway = new GatewayExt(LOCAL_CENT_ID, IRoot(address(root)), address(this));

    address immutable ANY = makeAddr("ANY");
    address immutable MANAGER = makeAddr("MANAGER");
    address immutable REFUND = makeAddr("REFUND");
    address NO_PAYABLE_DESTINATION = address(new NoPayableDestination());

    receive() external payable {}

    function _mockAdapter(uint16 centrifugeId, bytes memory message, uint256 gasLimit, address refund) internal {
        vm.mockCall(
            address(adapter),
            abi.encodeWithSelector(IAdapter.estimate.selector, centrifugeId, message, gasLimit),
            abi.encode(gasLimit + ADAPTER_ESTIMATE)
        );

        vm.mockCall(
            address(adapter),
            gasLimit + ADAPTER_ESTIMATE,
            abi.encodeWithSelector(IAdapter.send.selector, centrifugeId, message, gasLimit, refund),
            abi.encode(ADAPTER_DATA)
        );
    }

    function _mockPause(bool isPaused) internal {
        vm.mockCall(address(root), abi.encodeWithSelector(IProtocolPauser.paused.selector), abi.encode(isPaused));
    }

    function setUp() public virtual {
        gateway.file("adapter", address(adapter));
        gateway.file("processor", address(processor));
        gateway.file("messageProperties", address(messageProperties));

        _mockPause(false);
    }
}

contract GatewayTestFile is GatewayTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.file("unknown", address(1));
    }

    function testErrFileUnrecognizedParam() public {
        vm.expectRevert(IGateway.FileUnrecognizedParam.selector);
        gateway.file("unknown", address(1));
    }

    function testGatewayFile() public {
        vm.expectEmit();
        emit IGateway.File("processor", address(23));
        gateway.file("processor", address(23));
        assertEq(address(gateway.processor()), address(23));

        gateway.file("messageProperties", address(42));
        assertEq(address(gateway.messageProperties()), address(42));

        gateway.file("adapter", address(88));
        assertEq(address(gateway.adapter()), address(88));
    }
}

contract GatewayTestUpdateManager is GatewayTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.updateManager(POOL_A, MANAGER, true);
    }

    function testUpdateManager() public {
        vm.expectEmit();
        emit IGateway.UpdateManager(POOL_A, MANAGER, true);
        gateway.updateManager(POOL_A, MANAGER, true);

        assertEq(gateway.manager(POOL_A, MANAGER), true);
    }
}

contract GatewayTestHandle is GatewayTest {
    function testErrPaused() public {
        _mockPause(true);
        vm.expectRevert(IGateway.Paused.selector);
        gateway.handle(REMOTE_CENT_ID, new bytes(0));
    }

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.handle(REMOTE_CENT_ID, new bytes(0));
    }

    function testNotEnoughGas() public {
        bytes memory batch = MessageKind.WithPool0.asBytes();

        vm.expectRevert(IGateway.NotEnoughGas.selector);
        gateway.handle{gas: MESSAGE_PROCESSING_GAS_LIMIT}(REMOTE_CENT_ID, batch);
    }

    function testErrMalformedBatch() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPool0.asBytes();
        bytes memory batch = abi.encodePacked(message1, message2);

        vm.expectRevert(IGateway.MalformedBatch.selector);
        gateway.handle(REMOTE_CENT_ID, batch);
    }

    function testMessage() public {
        bytes memory batch = MessageKind.WithPool0.asBytes();

        vm.expectEmit();
        emit IGateway.ExecuteMessage(REMOTE_CENT_ID, keccak256(batch));
        gateway.handle(REMOTE_CENT_ID, batch);

        assertEq(processor.processed(REMOTE_CENT_ID, 0), batch);
    }

    function testMessageFailed() public {
        bytes memory batch = MessageKind.WithPoolAFail.asBytes();

        vm.expectEmit();
        emit IGateway.FailMessage(
            REMOTE_CENT_ID, keccak256(batch), abi.encodeWithSelector(MockProcessor.HandleError.selector)
        );
        gateway.handle(REMOTE_CENT_ID, batch);

        assertEq(processor.count(REMOTE_CENT_ID), 0);
        assertEq(gateway.failedMessages(REMOTE_CENT_ID, keccak256(batch)), 1);
    }

    function testBatchProcessing() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        bytes memory batch = abi.encodePacked(message1, message2);

        gateway.handle(REMOTE_CENT_ID, batch);

        assertEq(processor.count(REMOTE_CENT_ID), 2);
        assertEq(processor.processed(REMOTE_CENT_ID, 0), message1);
        assertEq(processor.processed(REMOTE_CENT_ID, 1), message2);
    }

    function testBatchWithFailingMessages() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolAFail.asBytes();
        bytes memory message3 = MessageKind.WithPoolA2.asBytes();
        bytes memory batch = abi.encodePacked(message1, message2, message3);

        gateway.handle(REMOTE_CENT_ID, batch);

        assertEq(processor.count(REMOTE_CENT_ID), 2);
        assertEq(processor.processed(REMOTE_CENT_ID, 0), message1);
        assertEq(processor.processed(REMOTE_CENT_ID, 1), message3);

        assertEq(gateway.failedMessages(REMOTE_CENT_ID, keccak256(message2)), 1);
    }

    function testMultipleSameFailingMessages() public {
        bytes memory batch = MessageKind.WithPoolAFail.asBytes();

        gateway.handle(REMOTE_CENT_ID, batch);
        gateway.handle(REMOTE_CENT_ID, batch);

        assertEq(gateway.failedMessages(REMOTE_CENT_ID, keccak256(batch)), 2);
    }

    function testBatchWithMultipleSameFailingMessages() public {
        bytes memory message = MessageKind.WithPoolAFail.asBytes();
        bytes memory batch = abi.encodePacked(message, message);

        gateway.handle(REMOTE_CENT_ID, batch);

        assertEq(gateway.failedMessages(REMOTE_CENT_ID, keccak256(message)), 2);
    }

    function testMessageFailBenchmark() public {
        bytes memory message = MessageKind.WithPoolALongFail.asBytes();
        bytes32 messageHash = keccak256(message);

        gateway.safeProcess(REMOTE_CENT_ID, message, messageHash, MESSAGE_OVERALL_GAS_LIMIT);
    }
}

contract GatewayTestRetry is GatewayTest {
    function testErrPaused() public {
        _mockPause(true);
        vm.expectRevert(IGateway.Paused.selector);
        gateway.retry(REMOTE_CENT_ID, bytes(""));
    }

    function testErrNotFailedMessage() public {
        vm.expectRevert(IGateway.NotFailedMessage.selector);
        gateway.retry(REMOTE_CENT_ID, bytes("noMessage"));
    }

    function testRecoverFailingMessage() public {
        bytes memory batch = MessageKind.WithPoolAFail.asBytes();

        gateway.handle(REMOTE_CENT_ID, batch);

        processor.disableFailure();

        vm.prank(ANY);
        emit IGateway.ExecuteMessage(REMOTE_CENT_ID, keccak256(batch));
        gateway.retry(REMOTE_CENT_ID, batch);

        assertEq(gateway.failedMessages(REMOTE_CENT_ID, keccak256(batch)), 0);
        assertEq(processor.processed(REMOTE_CENT_ID, 0), batch);
    }

    function testRecoverMultipleFailingMessage() public {
        bytes memory batch = MessageKind.WithPoolAFail.asBytes();

        gateway.handle(REMOTE_CENT_ID, batch);
        gateway.handle(REMOTE_CENT_ID, batch);

        processor.disableFailure();

        vm.prank(ANY);
        gateway.retry(REMOTE_CENT_ID, batch);
        vm.prank(ANY);
        gateway.retry(REMOTE_CENT_ID, batch);

        assertEq(processor.count(REMOTE_CENT_ID), 2);
        assertEq(processor.processed(REMOTE_CENT_ID, 0), batch);
        assertEq(processor.processed(REMOTE_CENT_ID, 1), batch);
        assertEq(gateway.failedMessages(REMOTE_CENT_ID, keccak256(batch)), 0);
    }
}

contract GatewayTestSend is GatewayTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.send(REMOTE_CENT_ID, new bytes(0), false, REFUND);
    }

    function testErrPaused() public {
        _mockPause(true);
        vm.expectRevert(IGateway.Paused.selector);
        gateway.send(REMOTE_CENT_ID, new bytes(0), false, REFUND);
    }

    function testErrEmptyMessage() public {
        vm.expectRevert(IGateway.EmptyMessage.selector);
        gateway.send(REMOTE_CENT_ID, new bytes(0), false, REFUND);
    }

    function testErrTooLongMessage() public {
        bytes memory message = MessageKind.WithPoolATooLong.asBytes();

        vm.expectRevert(IGateway.TooLongMessage.selector);
        gateway.send(REMOTE_CENT_ID, message, false, REFUND);
    }

    function testErrNotPayable() public {
        gateway.startBatching();
        vm.expectRevert(IGateway.NotPayable.selector);
        gateway.send{value: 1}(REMOTE_CENT_ID, MessageKind.WithPoolA1.asBytes(), false, REFUND);
    }

    function testErrOutgoingBlocked() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        gateway.updateManager(POOL_A, MANAGER, true);

        vm.prank(MANAGER);
        gateway.blockOutgoing(REMOTE_CENT_ID, POOL_A, true);

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_OVERALL_GAS_LIMIT, REFUND);

        vm.expectRevert(IGateway.OutgoingBlocked.selector);
        gateway.send(REMOTE_CENT_ID, message, false, REFUND);
    }

    function testErrCannotRefund() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        uint256 cost = MESSAGE_OVERALL_GAS_LIMIT + ADAPTER_ESTIMATE;

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_OVERALL_GAS_LIMIT, NO_PAYABLE_DESTINATION);

        vm.expectRevert(IGateway.CannotRefund.selector);
        gateway.send{value: cost + 1234}(REMOTE_CENT_ID, message, false, NO_PAYABLE_DESTINATION);
    }

    function testErrNotEnoughGas() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        uint256 cost = MESSAGE_OVERALL_GAS_LIMIT + ADAPTER_ESTIMATE;

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_OVERALL_GAS_LIMIT, REFUND);

        vm.expectRevert(IGateway.NotEnoughGas.selector);
        gateway.send{value: cost - 1}(REMOTE_CENT_ID, message, false, REFUND);
    }

    function testErrMessageTooExpensive() public {
        bytes memory message = MessageKind.WithPoolA1TooMuchGas.asBytes();

        vm.expectRevert(IGateway.BatchTooExpensive.selector);
        gateway.send(REMOTE_CENT_ID, message, false, REFUND);
    }

    function testErrBatchTooExpensive() public {
        bytes memory message = MessageKind.WithPoolA1TooMuchGas.asBytes();

        gateway.startBatching();

        vm.expectRevert(IGateway.BatchTooExpensive.selector);
        gateway.send(REMOTE_CENT_ID, message, false, REFUND);
    }

    function testMessageWasBatched() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();

        gateway.startBatching();

        vm.expectEmit();
        emit IGateway.PrepareMessage(REMOTE_CENT_ID, POOL_A, message);
        gateway.send(REMOTE_CENT_ID, message, false, address(0));

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), MESSAGE_OVERALL_GAS_LIMIT);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), message);
        assertEq(gateway.batchLocatorsLength(), 1);

        (uint16 centrifugeId, PoolId poolId) = gateway.batchLocators(0);
        assertEq(centrifugeId, REMOTE_CENT_ID);
        assertEq(poolId.raw(), POOL_A.raw());
    }

    function testSecondMessageWasBatchedSamePoolSameChain() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1, false, address(0));
        gateway.send(REMOTE_CENT_ID, message2, false, address(0));

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), MESSAGE_OVERALL_GAS_LIMIT * 2);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), abi.encodePacked(message1, message2));
        assertEq(gateway.batchLocatorsLength(), 1);
    }

    function testSecondMessageWasBatchedSamePoolDifferentChain() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1, false, address(0));
        gateway.send(REMOTE_CENT_ID + 1, message2, false, address(0));

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), MESSAGE_OVERALL_GAS_LIMIT);
        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID + 1, POOL_A), MESSAGE_OVERALL_GAS_LIMIT);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), message1);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID + 1, POOL_A), message2);
        assertEq(gateway.batchLocatorsLength(), 2);
    }

    function testSecondMessageWasBatchedDifferentPoolSameChain() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPool0.asBytes();

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1, false, address(0));
        gateway.send(REMOTE_CENT_ID, message2, false, address(0));

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), MESSAGE_OVERALL_GAS_LIMIT);
        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_0), MESSAGE_OVERALL_GAS_LIMIT);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), message1);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_0), message2);
        assertEq(gateway.batchLocatorsLength(), 2);
    }

    function testSendMessageUnderpaid() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(message);
        uint256 cost = MESSAGE_OVERALL_GAS_LIMIT + ADAPTER_ESTIMATE;

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_OVERALL_GAS_LIMIT, REFUND);

        vm.expectEmit();
        emit IGateway.PrepareMessage(REMOTE_CENT_ID, POOL_A, message);
        vm.expectEmit();
        emit IGateway.UnderpaidBatch(REMOTE_CENT_ID, message, batchHash);
        gateway.send{value: cost - 1}(REMOTE_CENT_ID, message, true, REFUND);

        (uint128 gasLimit, uint64 counter) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(counter, 1);
        assertEq(gasLimit, MESSAGE_OVERALL_GAS_LIMIT);
    }

    function testSendMessageUnderpaidTwice() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(message);
        uint256 cost = MESSAGE_OVERALL_GAS_LIMIT + ADAPTER_ESTIMATE;

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_OVERALL_GAS_LIMIT, REFUND);

        gateway.send{value: cost - 1}(REMOTE_CENT_ID, message, true, REFUND);
        gateway.send{value: cost - 1}(REMOTE_CENT_ID, message, true, REFUND);

        (uint128 gasLimit, uint64 counter) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(counter, 2);
        assertEq(gasLimit, MESSAGE_OVERALL_GAS_LIMIT);
    }

    function testSendMessage() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        uint256 cost = MESSAGE_OVERALL_GAS_LIMIT + ADAPTER_ESTIMATE;

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_OVERALL_GAS_LIMIT, REFUND);

        vm.expectEmit();
        emit IGateway.PrepareMessage(REMOTE_CENT_ID, POOL_A, message);
        gateway.send{value: cost + 1234}(REMOTE_CENT_ID, message, false, REFUND);

        assertEq(REFUND.balance, 1234);
    }

    function testSendMessageWithExtraGasLimit() public {
        bytes memory message = MessageKind.WithPoolA1ExtraGas.asBytes();
        uint256 cost = MESSAGE_OVERALL_GAS_LIMIT + ADAPTER_ESTIMATE + EXTRA_GAS_LIMIT;

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_OVERALL_GAS_LIMIT + EXTRA_GAS_LIMIT, REFUND);

        gateway.send{value: cost + 1234}(REMOTE_CENT_ID, message, false, REFUND);

        assertEq(REFUND.balance, 1234);
    }

    function testSendMessageBatchedWithExtraGasLimit() public {
        bytes memory message = MessageKind.WithPoolA1ExtraGas.asBytes();

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message, false, address(0));
        gateway.send(REMOTE_CENT_ID, message, false, address(0));

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), (MESSAGE_OVERALL_GAS_LIMIT + EXTRA_GAS_LIMIT) * 2);
    }
}

contract GatewayTestEndBatching is GatewayTest {
    function testErrNoBatched() public {
        vm.expectRevert(IGateway.NoBatched.selector);
        gateway.endBatching(REFUND);
    }

    function testSendTwoMessageBatching() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        bytes memory batch = bytes.concat(message1, message2);
        uint256 cost = MESSAGE_OVERALL_GAS_LIMIT * 2 + ADAPTER_ESTIMATE;

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1, false, address(0));
        gateway.send(REMOTE_CENT_ID, message2, false, address(0));

        _mockAdapter(REMOTE_CENT_ID, batch, MESSAGE_OVERALL_GAS_LIMIT * 2, REFUND);

        gateway.endBatching{value: cost + 1234}(REFUND);

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), 0);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), new bytes(0));
        assertEq(gateway.batchLocatorsLength(), 0);
        assertEq(gateway.isBatching(), false);
    }

    function testSendTwoMessageBatchingDifferentChainSamePool() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        uint256 cost = (MESSAGE_OVERALL_GAS_LIMIT + ADAPTER_ESTIMATE) * 2;

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1, false, address(0));
        gateway.send(REMOTE_CENT_ID + 1, message2, false, address(0));

        _mockAdapter(REMOTE_CENT_ID, message1, MESSAGE_OVERALL_GAS_LIMIT, REFUND);
        _mockAdapter(REMOTE_CENT_ID + 1, message2, MESSAGE_OVERALL_GAS_LIMIT, REFUND);

        gateway.endBatching{value: cost + 1234}(REFUND);

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), 0);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), new bytes(0));
        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID + 1, POOL_A), 0);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID + 1, POOL_A), new bytes(0));
        assertEq(gateway.batchLocatorsLength(), 0);
        assertEq(gateway.isBatching(), false);
    }

    function testSendTwoMessageBatchingSameChainDifferentPool() public {
        bytes memory message1 = MessageKind.WithPool0.asBytes();
        bytes memory message2 = MessageKind.WithPoolA1.asBytes();

        uint256 cost = MESSAGE_OVERALL_GAS_LIMIT + ADAPTER_ESTIMATE;

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1, false, address(0));
        gateway.send(REMOTE_CENT_ID, message2, false, address(0));

        _mockAdapter(REMOTE_CENT_ID, message1, MESSAGE_OVERALL_GAS_LIMIT, REFUND);
        _mockAdapter(REMOTE_CENT_ID, message2, MESSAGE_OVERALL_GAS_LIMIT, REFUND);

        gateway.endBatching{value: cost * 2 + 1234}(REFUND);

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), 0);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), new bytes(0));
        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_0), 0);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_0), new bytes(0));
        assertEq(gateway.batchLocatorsLength(), 0);
        assertEq(gateway.isBatching(), false);
    }

    function testSendUnpaidMessage() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(message);

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_OVERALL_GAS_LIMIT, address(0));

        vm.expectEmit();
        emit IGateway.PrepareMessage(REMOTE_CENT_ID, POOL_A, message);
        vm.expectEmit();
        emit IGateway.UnderpaidBatch(REMOTE_CENT_ID, message, batchHash);
        gateway.send(REMOTE_CENT_ID, message, true, address(0));

        (uint128 gasLimit, uint64 counter) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(counter, 1);
        assertEq(gasLimit, MESSAGE_OVERALL_GAS_LIMIT);
    }

    function testSendUnpaidMessageTwice() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(message);

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_OVERALL_GAS_LIMIT, address(0));

        gateway.send(REMOTE_CENT_ID, message, true, address(0));
        gateway.send(REMOTE_CENT_ID, message, true, address(0));

        (uint128 gasLimit, uint64 counter) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(counter, 2);
        assertEq(gasLimit, MESSAGE_OVERALL_GAS_LIMIT);
    }

    function testSendUnpaidMessageWithExtraGas() public {
        bytes memory message = MessageKind.WithPoolA1ExtraGas.asBytes();
        bytes32 batchHash = keccak256(message);

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_OVERALL_GAS_LIMIT + EXTRA_GAS_LIMIT, address(0));

        gateway.send(REMOTE_CENT_ID, message, true, address(0));

        (uint128 gasLimit,) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(gasLimit, MESSAGE_OVERALL_GAS_LIMIT + EXTRA_GAS_LIMIT);
    }
}

contract GatewayTestRepay is GatewayTest {
    function testErrPaused() public {
        _mockPause(true);
        vm.expectRevert(IGateway.Paused.selector);
        gateway.repay(REMOTE_CENT_ID, new bytes(0), REFUND);
    }

    function testErrNotUnderpaidBatch() public {
        bytes memory batch = MessageKind.WithPoolA1.asBytes();

        vm.expectRevert(IGateway.NotUnderpaidBatch.selector);
        gateway.repay(REMOTE_CENT_ID, batch, REFUND);
    }

    function testErrOutgoingBlocked() public {
        bytes memory batch = MessageKind.WithPoolA1.asBytes();
        gateway.updateManager(POOL_A, MANAGER, true);

        _mockAdapter(REMOTE_CENT_ID, batch, MESSAGE_OVERALL_GAS_LIMIT, address(this));
        gateway.send(REMOTE_CENT_ID, batch, true, address(0));
        uint256 payment = MESSAGE_OVERALL_GAS_LIMIT + ADAPTER_ESTIMATE;

        vm.prank(MANAGER);
        gateway.blockOutgoing(REMOTE_CENT_ID, POOL_A, true);

        vm.expectRevert(IGateway.OutgoingBlocked.selector);
        gateway.repay{value: payment}(REMOTE_CENT_ID, batch, REFUND);
    }

    function testCorrectRepay() public {
        bytes memory batch = MessageKind.WithPoolA1.asBytes();

        _mockAdapter(REMOTE_CENT_ID, batch, MESSAGE_OVERALL_GAS_LIMIT, REFUND);
        gateway.send(REMOTE_CENT_ID, batch, true, address(0));

        uint256 payment = MESSAGE_OVERALL_GAS_LIMIT + ADAPTER_ESTIMATE + 1234;
        vm.deal(ANY, payment);
        vm.prank(ANY);
        vm.expectEmit();
        emit IGateway.RepayBatch(REMOTE_CENT_ID, batch);
        gateway.repay{value: payment}(REMOTE_CENT_ID, batch, REFUND);

        (uint128 gasLimit, uint64 counter) = gateway.underpaid(REMOTE_CENT_ID, keccak256(batch));
        assertEq(counter, 0);
        assertEq(gasLimit, 0);

        assertEq(address(REFUND).balance, 1234); // Excees is refunded
    }
}

contract GatewayTestBlockOutgoing is GatewayTest {
    function testErrManagerNotAllowed() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.blockOutgoing(REMOTE_CENT_ID, POOL_A, false);
    }

    function testBlockOutgoing() public {
        gateway.updateManager(POOL_A, MANAGER, true);

        vm.prank(MANAGER);
        vm.expectEmit();
        emit IGateway.BlockOutgoing(REMOTE_CENT_ID, POOL_A, true);
        gateway.blockOutgoing(REMOTE_CENT_ID, POOL_A, true);

        assertEq(gateway.isOutgoingBlocked(REMOTE_CENT_ID, POOL_A), true);
    }
}

contract IntegrationMock is Test {
    bool public wasCalled;
    GatewayExt public gateway;
    uint256 public constant PAYMENT = 234;

    constructor(GatewayExt gateway_) {
        gateway = gateway_;
    }

    function _nested(address refund) external payable {
        gateway.lockCallback();
        assertEq(msg.value, 1234);
        gateway.withBatch{value: msg.value}(abi.encodeWithSelector(this._success.selector, false, 2), refund);
    }

    function _emptyError() external {
        gateway.lockCallback();
        revert();
    }

    function _notLocked() external {}

    function _success(bool, uint256) external {
        assertEq(gateway.batcher(), address(this));
        gateway.lockCallback();
        wasCalled = true;
    }

    function _justLock() external {
        gateway.lockCallback();
    }

    function _paid() external payable {
        assertEq(msg.value, PAYMENT);
        gateway.lockCallback();
    }

    function callNested(address refund) external payable {
        gateway.withBatch{value: msg.value}(abi.encodeWithSelector(this._nested.selector, refund), msg.value, refund);
    }

    function callEmptyError(address refund) external {
        gateway.withBatch(abi.encodeWithSelector(this._emptyError.selector), refund);
    }

    function callSuccess(address refund) external payable {
        gateway.withBatch{value: msg.value}(abi.encodeWithSelector(this._success.selector, true, 1), refund);
    }

    function callNotLocked(address refund) external {
        gateway.withBatch(abi.encodeWithSelector(this._notLocked.selector), refund);
    }

    function callPaid(address refund, uint256 value) external payable {
        gateway.withBatch{value: msg.value}(abi.encodeWithSelector(this._paid.selector), value, refund);
    }
}

contract AttackerIntegrationMock is Test {
    IntegrationMock prey;
    IGateway gateway;

    constructor(IGateway gateway_, IntegrationMock prey_) {
        gateway = gateway_;
        prey = prey_;
    }

    function callAttack(address refund) external {
        gateway.withBatch(abi.encodeWithSelector(this._attack.selector), refund);
    }

    function _attack() external payable {
        prey._justLock();
    }
}

contract GatewayTestWithBatch is GatewayTest {
    IntegrationMock integration;
    AttackerIntegrationMock attacker;

    function setUp() public override {
        super.setUp();
        integration = new IntegrationMock(gateway);
        attacker = new AttackerIntegrationMock(gateway, integration);
    }

    function testErrCallFailedWithEmptyRevert() public {
        vm.prank(ANY);
        vm.expectRevert(IGateway.CallFailedWithEmptyRevert.selector);
        integration.callEmptyError(REFUND);
    }

    function testErrCallbackWasNotLocked() public {
        vm.prank(ANY);
        vm.expectRevert(IGateway.CallbackWasNotLocked.selector);
        integration.callNotLocked(REFUND);
    }

    function testErrCallbackWasNotFromSender() public {
        vm.prank(ANY);
        vm.expectRevert(IGateway.CallbackWasNotFromSender.selector);
        attacker.callAttack(REFUND);
    }

    function testErrNotEnoughValueForCallback() public {
        vm.prank(ANY);
        vm.deal(ANY, 1234);
        vm.expectRevert(IGateway.NotEnoughValueForCallback.selector);
        integration.callPaid{value: 1234}(REFUND, 2000);
    }

    function testWithCallback() public {
        vm.prank(ANY);
        vm.deal(ANY, 1234);
        integration.callSuccess{value: 1234}(REFUND);

        assertEq(integration.wasCalled(), true);
        assertEq(REFUND.balance, 1234);
    }

    function testWithCallbackNested() public {
        vm.prank(ANY);
        vm.deal(ANY, 1234);
        integration.callNested{value: 1234}(REFUND);

        assertEq(integration.wasCalled(), true);
        assertEq(REFUND.balance, 1234); // Refunded by the nested withBatch
    }

    function testWithCallbackPaid() public {
        vm.prank(ANY);
        vm.deal(ANY, 1234);
        integration.callPaid{value: 1234}(REFUND, integration.PAYMENT());

        assertEq(REFUND.balance, 1000);
        assertEq(address(integration).balance, integration.PAYMENT());
    }
}

contract GatewayTestLockCallback is GatewayTest {
    function testErrCallbackIsLocked() public {
        vm.expectRevert(IGateway.CallbackIsLocked.selector);
        gateway.lockCallback();
    }
}

contract ReentrantWithBatchAdapter is IAdapter {
    IGateway public gateway;

    constructor(IGateway gateway_) {
        gateway = gateway_;
    }

    function estimate(uint16, bytes calldata, uint256) external pure override returns (uint256) {
        return 1;
    }

    function send(uint16, bytes calldata, uint256, address refund) external payable override returns (bytes32) {
        // Attempt to reenter via withBatch during the send loop
        gateway.withBatch(abi.encodeWithSelector(this.callback.selector), refund);
        return bytes32(0);
    }

    function callback() external {
        gateway.lockCallback();
    }
}

contract ReentrantSendAdapter is IAdapter, Test {
    IGateway public gateway;
    address public sender;

    constructor(address sender_, IGateway gateway_) {
        gateway = gateway_;
        sender = sender_;
    }

    function estimate(uint16, bytes calldata, uint256) external pure override returns (uint256) {
        return 1;
    }

    function send(uint16, bytes calldata, uint256, address refund) external payable override returns (bytes32) {
        // Attempt to reenter via send during the send loop
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        vm.prank(sender);
        gateway.send(REMOTE_CENT_ID, message, false, refund);
        return bytes32(0);
    }
}

contract GatewayTestReentrancyProtection is GatewayTest {
    function _testBase(IAdapter adapter) internal {
        gateway.file("adapter", address(adapter));

        bytes memory message = MessageKind.WithPoolA1.asBytes();

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message, false, address(0));

        vm.expectRevert(IGateway.ReentrantBatchCreation.selector);
        gateway.endBatching{value: MESSAGE_OVERALL_GAS_LIMIT}(REFUND);
    }

    function testErrReentrantBatchCreationWithBatch() public {
        _testBase(new ReentrantWithBatchAdapter(gateway));
    }

    function testErrReentrantBatchCreationSend() public {
        _testBase(new ReentrantSendAdapter(address(this), gateway));
    }
}
