// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth, IAuth} from "../../../src/misc/Auth.sol";
import {Recoverable} from "../../../src/misc/Recoverable.sol";
import {BytesLib} from "../../../src/misc/libraries/BytesLib.sol";
import {TransientArrayLib} from "../../../src/misc/libraries/TransientArrayLib.sol";
import {TransientBytesLib} from "../../../src/misc/libraries/TransientBytesLib.sol";
import {TransientStorageLib} from "../../../src/misc/libraries/TransientStorageLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
import {Gateway, IRoot, IGasService, IGateway} from "../../../src/common/Gateway.sol";
import {IMessageProperties} from "../../../src/common/interfaces/IMessageProperties.sol";

import "forge-std/Test.sol";

// -----------------------------------------
//     MESSAGE MOCKING
// -----------------------------------------

PoolId constant POOL_A = PoolId.wrap(23);
PoolId constant POOL_0 = PoolId.wrap(0);

enum MessageKind {
    _Invalid,
    _MessageProof,
    Recovery,
    WithPool0,
    WithPoolA1,
    WithPoolA2,
    WithPoolAFail
}

function length(MessageKind kind) pure returns (uint16) {
    if (kind == MessageKind.WithPool0) return 5;
    if (kind == MessageKind.WithPoolA1) return 10;
    if (kind == MessageKind.WithPoolA2) return 15;
    if (kind == MessageKind.WithPoolAFail) return 250;
    return 2;
}

function asBytes(MessageKind kind) pure returns (bytes memory) {
    bytes memory encoded = new bytes(length(kind));
    encoded[0] = bytes1(uint8(kind));
    return encoded;
}

using {asBytes, length} for MessageKind;

// A MessageLib agnostic processor
contract MockProcessor is IMessageProperties {
    using BytesLib for bytes;

    error HandleError();

    mapping(uint16 => bytes[]) public processed;
    bool shouldNotFail;

    function disableFailure() public {
        shouldNotFail = true;
    }

    function handle(uint16 centrifugeId, bytes memory payload) external {
        if (payload.toUint8(0) == uint8(MessageKind.WithPoolAFail) && !shouldNotFail) {
            revert HandleError();
        }
        processed[centrifugeId].push(payload);
    }

    function count(uint16 centrifugeId) external view returns (uint256) {
        return processed[centrifugeId].length;
    }

    function messageLength(bytes calldata message) external pure returns (uint16) {
        return MessageKind(message.toUint8(0)).length();
    }

    function messagePoolId(bytes calldata message) external pure returns (PoolId) {
        if (message.toUint8(0) == uint8(MessageKind.WithPool0)) return POOL_0;
        if (message.toUint8(0) == uint8(MessageKind.WithPoolA1)) return POOL_A;
        if (message.toUint8(0) == uint8(MessageKind.WithPoolA2)) return POOL_A;
        revert("Unreachable: message never asked for pool");
    }
}

contract MockPoolRefund is Recoverable {
    constructor(address authorized) Auth(authorized) {}
    receive() external payable {}
}

contract NoPayableDestination {}

// -----------------------------------------
//     GATEWAY EXTENSION
// -----------------------------------------

contract GatewayExt is Gateway {
    constructor(uint16 localCentrifugeId, IRoot root_, IGasService gasService_, address deployer)
        Gateway(localCentrifugeId, root_, gasService_, deployer)
    {}

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

    function process(uint16 centrifugeId, bytes memory message, bytes32 messageHash) public {
        _process(centrifugeId, message, messageHash);
    }
}

// -----------------------------------------
//     GATEWAY TESTS
// -----------------------------------------

contract GatewayTest is Test {
    uint16 constant LOCAL_CENT_ID = 23;
    uint16 constant REMOTE_CENT_ID = 24;

    uint256 constant ADAPTER_ESTIMATE = 1;
    bytes32 constant ADAPTER_DATA = bytes32("adapter data");

    uint256 constant MESSAGE_GAS_LIMIT = 100_000;
    uint256 constant MAX_BATCH_GAS_LIMIT = 500_000;
    uint128 constant EXTRA_GAS_LIMIT = 10;
    bool constant NO_SUBSIDIZED = false;

    IGasService gasService = IGasService(makeAddr("GasService"));
    IRoot root = IRoot(makeAddr("Root"));
    IAdapter adapter = IAdapter(makeAddr("Adapter"));

    MockProcessor processor = new MockProcessor();
    GatewayExt gateway = new GatewayExt(LOCAL_CENT_ID, IRoot(address(root)), gasService, address(this));

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

    function _mockGasService() internal {
        vm.mockCall(
            address(gasService),
            abi.encodeWithSelector(IGasService.messageGasLimit.selector),
            abi.encode(MESSAGE_GAS_LIMIT)
        );
        vm.mockCall(
            address(gasService),
            abi.encodeWithSelector(IGasService.maxBatchGasLimit.selector),
            abi.encode(MAX_BATCH_GAS_LIMIT)
        );
    }

    function _mockPause(bool isPaused) internal {
        vm.mockCall(address(root), abi.encodeWithSelector(IRoot.paused.selector), abi.encode(isPaused));
    }

    function setUp() public virtual {
        gateway.file("adapter", address(adapter));
        gateway.file("processor", address(processor));

        _mockPause(false);
        _mockGasService();
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

        gateway.file("gasService", address(42));
        assertEq(address(gateway.gasService()), address(42));

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

    function testErrNotEnoughGasToProcess() public {
        bytes memory batch = MessageKind.WithPool0.asBytes();
        uint256 gas = MESSAGE_GAS_LIMIT + gateway.GAS_FAIL_MESSAGE_STORAGE();

        vm.expectRevert(IGateway.NotEnoughGasToProcess.selector);

        // NOTE: The own handle() also consume some gas, so passing gas + <small value> can also make it fails
        gateway.handle{gas: gas - 1}(REMOTE_CENT_ID, batch);
    }

    function testMessage() public {
        bytes memory batch = MessageKind.WithPool0.asBytes();

        vm.expectEmit();
        emit IGateway.ExecuteMessage(REMOTE_CENT_ID, batch, keccak256(batch));
        gateway.handle(REMOTE_CENT_ID, batch);

        assertEq(processor.processed(REMOTE_CENT_ID, 0), batch);
    }

    function testMessageFailed() public {
        bytes memory batch = MessageKind.WithPoolAFail.asBytes();

        vm.expectEmit();
        emit IGateway.FailMessage(REMOTE_CENT_ID, batch, keccak256(batch), abi.encodeWithSignature("HandleError()"));
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
        bytes memory message = MessageKind.WithPoolAFail.asBytes();
        bytes32 messageHash = keccak256(message);

        gateway.process(REMOTE_CENT_ID, message, messageHash);
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
        emit IGateway.ExecuteMessage(REMOTE_CENT_ID, batch, keccak256(batch));
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

contract GatewayTestStartBatching is GatewayTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.startBatching();
    }

    function testErrAlreadyBatching() public {
        gateway.startBatching();

        vm.expectRevert(IGateway.AlreadyBatching.selector);
        gateway.startBatching();
    }

    function testStartBatching() public {
        gateway.startBatching();

        assertEq(gateway.isBatching(), true);
    }

    /// forge-config: default.isolate = true
    function testStartBatchingIsTransactional() public {
        gateway.startBatching();

        assertEq(gateway.isBatching(), false);
    }
}

contract GatewayTestSend is GatewayTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.send(REMOTE_CENT_ID, new bytes(0), 0, REFUND);
    }

    function testErrPaused() public {
        _mockPause(true);
        vm.expectRevert(IGateway.Paused.selector);
        gateway.send(REMOTE_CENT_ID, new bytes(0), 0, REFUND);
    }

    function testErrEmptyMessage() public {
        vm.expectRevert(IGateway.EmptyMessage.selector);
        gateway.send(REMOTE_CENT_ID, new bytes(0), 0, REFUND);
    }

    function testErrExceedsMaxBatching() public {
        gateway.startBatching();
        uint256 maxMessages = MAX_BATCH_GAS_LIMIT / MESSAGE_GAS_LIMIT;

        for (uint256 i; i < maxMessages; i++) {
            gateway.send(REMOTE_CENT_ID, MessageKind.WithPoolA1.asBytes(), 0, REFUND);
        }

        vm.expectRevert(IGateway.ExceedsMaxGasLimit.selector);
        gateway.send(REMOTE_CENT_ID, MessageKind.WithPoolA1.asBytes(), 0, REFUND);
    }

    function testErrNotPayable() public {
        gateway.startBatching();
        vm.expectRevert(IGateway.NotPayable.selector);
        gateway.send{value: 1}(REMOTE_CENT_ID, MessageKind.WithPoolA1.asBytes(), 0, REFUND);
    }

    function testErrOutgoingBlocked() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        gateway.updateManager(POOL_A, MANAGER, true);

        vm.prank(MANAGER);
        gateway.blockOutgoing(REMOTE_CENT_ID, POOL_A, true);

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, REFUND);

        vm.expectRevert(IGateway.OutgoingBlocked.selector);
        gateway.send(REMOTE_CENT_ID, message, 0, REFUND);
    }

    function testErrCannotRefund() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        uint256 cost = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE;

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, NO_PAYABLE_DESTINATION);

        vm.expectRevert(IGateway.CannotRefund.selector);
        gateway.send{value: cost + 1234}(REMOTE_CENT_ID, message, 0, NO_PAYABLE_DESTINATION);
    }

    function testErrNotEnoughGas() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        uint256 cost = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE;

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, REFUND);

        vm.expectRevert(IGateway.NotEnoughGas.selector);
        gateway.send{value: cost - 1}(REMOTE_CENT_ID, message, 0, REFUND);
    }

    function testMessageWasBatched() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();

        gateway.startBatching();

        vm.expectEmit();
        emit IGateway.PrepareMessage(REMOTE_CENT_ID, POOL_A, message);
        gateway.send(REMOTE_CENT_ID, message, 0, address(0));

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), MESSAGE_GAS_LIMIT);
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
        gateway.send(REMOTE_CENT_ID, message1, 0, address(0));
        gateway.send(REMOTE_CENT_ID, message2, 0, address(0));

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), MESSAGE_GAS_LIMIT * 2);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), abi.encodePacked(message1, message2));
        assertEq(gateway.batchLocatorsLength(), 1);
    }

    function testSecondMessageWasBatchedSamePoolDifferentChain() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1, 0, address(0));
        gateway.send(REMOTE_CENT_ID + 1, message2, 0, address(0));

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), MESSAGE_GAS_LIMIT);
        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID + 1, POOL_A), MESSAGE_GAS_LIMIT);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), message1);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID + 1, POOL_A), message2);
        assertEq(gateway.batchLocatorsLength(), 2);
    }

    function testSecondMessageWasBatchedDifferentPoolSameChain() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPool0.asBytes();

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1, 0, address(0));
        gateway.send(REMOTE_CENT_ID, message2, 0, address(0));

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), MESSAGE_GAS_LIMIT);
        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_0), MESSAGE_GAS_LIMIT);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), message1);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_0), message2);
        assertEq(gateway.batchLocatorsLength(), 2);
    }

    function testSendMessageUnderpaid() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(message);
        uint256 cost = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE;

        gateway.setUnpaidMode(true);

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, REFUND);

        vm.expectEmit();
        emit IGateway.PrepareMessage(REMOTE_CENT_ID, POOL_A, message);
        vm.expectEmit();
        emit IGateway.UnderpaidBatch(REMOTE_CENT_ID, message, batchHash);
        gateway.send{value: cost - 1}(REMOTE_CENT_ID, message, 0, REFUND);

        (uint128 gasLimit, uint64 counter) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(counter, 1);
        assertEq(gasLimit, MESSAGE_GAS_LIMIT);
    }

    function testSendMessageUnderpaidTwice() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(message);
        uint256 cost = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE;

        gateway.setUnpaidMode(true);

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, REFUND);

        gateway.send{value: cost - 1}(REMOTE_CENT_ID, message, 0, REFUND);
        gateway.send{value: cost - 1}(REMOTE_CENT_ID, message, 0, REFUND);

        (uint128 gasLimit, uint64 counter) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(counter, 2);
        assertEq(gasLimit, MESSAGE_GAS_LIMIT);
    }

    function testSendMessage() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        uint256 cost = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE;

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, REFUND);

        vm.expectEmit();
        emit IGateway.PrepareMessage(REMOTE_CENT_ID, POOL_A, message);
        gateway.send{value: cost + 1234}(REMOTE_CENT_ID, message, 0, REFUND);

        assertEq(REFUND.balance, 1234);
    }

    function testSendMessageWithExtraGasLimit() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        uint256 cost = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE + EXTRA_GAS_LIMIT;

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT + EXTRA_GAS_LIMIT, REFUND);

        gateway.send{value: cost + 1234}(REMOTE_CENT_ID, message, EXTRA_GAS_LIMIT, REFUND);

        assertEq(REFUND.balance, 1234);
    }

    function testSendMessageBatchedWithExtraGasLimit() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message, EXTRA_GAS_LIMIT, address(0));
        gateway.send(REMOTE_CENT_ID, message, EXTRA_GAS_LIMIT, address(0));

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), (MESSAGE_GAS_LIMIT + EXTRA_GAS_LIMIT) * 2);
    }
}

contract GatewayTestEndBatching is GatewayTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.endBatching(REFUND);
    }

    function testErrNoBatched() public {
        vm.expectRevert(IGateway.NoBatched.selector);
        gateway.endBatching(REFUND);
    }

    function testSendTwoMessageBatching() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        bytes memory batch = bytes.concat(message1, message2);
        uint256 cost = MESSAGE_GAS_LIMIT * 2 + ADAPTER_ESTIMATE;

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1, 0, address(0));
        gateway.send(REMOTE_CENT_ID, message2, 0, address(0));

        _mockAdapter(REMOTE_CENT_ID, batch, MESSAGE_GAS_LIMIT * 2, REFUND);

        gateway.endBatching{value: cost + 1234}(REFUND);

        assertEq(REFUND.balance, 1234);
        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), 0);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), new bytes(0));
        assertEq(gateway.batchLocatorsLength(), 0);
        assertEq(gateway.isBatching(), false);
    }

    function testSendTwoMessageBatchingDifferentChainSamePool() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        uint256 cost = (MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE) * 2;

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1, 0, address(0));
        gateway.send(REMOTE_CENT_ID + 1, message2, 0, address(0));

        _mockAdapter(REMOTE_CENT_ID, message1, MESSAGE_GAS_LIMIT, REFUND);
        _mockAdapter(REMOTE_CENT_ID + 1, message2, MESSAGE_GAS_LIMIT, REFUND);

        gateway.endBatching{value: cost + 1234}(REFUND);

        assertEq(REFUND.balance, 1234);
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

        uint256 cost = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE;

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1, 0, address(0));
        gateway.send(REMOTE_CENT_ID, message2, 0, address(0));

        _mockAdapter(REMOTE_CENT_ID, message1, MESSAGE_GAS_LIMIT, REFUND);
        _mockAdapter(REMOTE_CENT_ID, message2, MESSAGE_GAS_LIMIT, REFUND);

        gateway.endBatching{value: cost * 2 + 1234}(REFUND);

        assertEq(REFUND.balance, 1234);
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

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, address(0));

        gateway.setUnpaidMode(true);
        vm.expectEmit();
        emit IGateway.PrepareMessage(REMOTE_CENT_ID, POOL_A, message);
        vm.expectEmit();
        emit IGateway.UnderpaidBatch(REMOTE_CENT_ID, message, batchHash);
        gateway.send(REMOTE_CENT_ID, message, 0, address(0));

        (uint128 gasLimit, uint64 counter) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(counter, 1);
        assertEq(gasLimit, MESSAGE_GAS_LIMIT);
    }

    function testSendUnpaidMessageTwice() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(message);

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, address(0));

        gateway.setUnpaidMode(true);
        gateway.send(REMOTE_CENT_ID, message, 0, address(0));
        gateway.send(REMOTE_CENT_ID, message, 0, address(0));

        (uint128 gasLimit, uint64 counter) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(counter, 2);
        assertEq(gasLimit, MESSAGE_GAS_LIMIT);
    }

    function testSendUnpaidMessageWithExtraGas() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(message);

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT + EXTRA_GAS_LIMIT, address(0));

        gateway.setUnpaidMode(true);
        gateway.send(REMOTE_CENT_ID, message, EXTRA_GAS_LIMIT, address(0));

        (uint128 gasLimit,) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(gasLimit, MESSAGE_GAS_LIMIT + EXTRA_GAS_LIMIT);
    }

    function testSendUnpaidBatch() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        bytes memory batch = bytes.concat(message1, message2);
        bytes32 batchHash = keccak256(batch);

        _mockAdapter(REMOTE_CENT_ID, batch, MESSAGE_GAS_LIMIT * 2, REFUND);

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1, 0, address(0));
        gateway.send(REMOTE_CENT_ID, message2, 0, address(0));
        gateway.setUnpaidMode(true);
        gateway.endBatching(REFUND);

        (uint128 gasLimit, uint64 counter) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(counter, 1);
        assertEq(gasLimit, MESSAGE_GAS_LIMIT * 2);
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

        _mockAdapter(REMOTE_CENT_ID, batch, MESSAGE_GAS_LIMIT, address(this));
        gateway.setUnpaidMode(true);
        gateway.send(REMOTE_CENT_ID, batch, 0, address(0));
        uint256 payment = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE;

        vm.prank(MANAGER);
        gateway.blockOutgoing(REMOTE_CENT_ID, POOL_A, true);

        vm.expectRevert(IGateway.OutgoingBlocked.selector);
        gateway.repay{value: payment}(REMOTE_CENT_ID, batch, REFUND);
    }

    function testCorrectRepay() public {
        bytes memory batch = MessageKind.WithPoolA1.asBytes();

        _mockAdapter(REMOTE_CENT_ID, batch, MESSAGE_GAS_LIMIT, REFUND);
        gateway.setUnpaidMode(true);
        gateway.send(REMOTE_CENT_ID, batch, 0, address(0));

        uint256 payment = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE + 1234;
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

    function testCorrectRepayForBatches() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        bytes memory batch = bytes.concat(message1, message2);

        gateway.setUnpaidMode(true);
        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1, 0, address(0));
        gateway.send(REMOTE_CENT_ID, message2, 0, address(0));

        _mockAdapter(REMOTE_CENT_ID, batch, MESSAGE_GAS_LIMIT * 2, REFUND);
        gateway.endBatching(REFUND);

        uint256 payment = MESSAGE_GAS_LIMIT * 2 + ADAPTER_ESTIMATE + 1234;
        vm.deal(ANY, payment);
        vm.prank(ANY);
        vm.expectEmit();
        emit IGateway.RepayBatch(REMOTE_CENT_ID, batch);
        gateway.repay{value: payment}(REMOTE_CENT_ID, batch, REFUND);

        assertEq(address(REFUND).balance, 1234); // Excees is refunded
    }
}

contract GatewayTestSetUnpaidMode is GatewayTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.setUnpaidMode(true);
    }

    function testSetUnpaidMode() public {
        gateway.setUnpaidMode(true);
        assertEq(gateway.unpaidMode(), true);
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
    IGateway public gateway;

    constructor(IGateway gateway_) {
        gateway = gateway_;
    }

    function _success(bool, uint256) external payable {
        assertEq(gateway.batcher(), address(this));
        wasCalled = true;
    }

    function _nested() external payable {
        gateway.withBatch(abi.encodeWithSelector(this._nested.selector), address(0));
    }

    function _emptyError() external payable {
        revert();
    }

    function callNested(address refund) external {
        gateway.withBatch(abi.encodeWithSelector(this._nested.selector), refund);
    }

    function callEmptyError(address refund) external {
        gateway.withBatch(abi.encodeWithSelector(this._emptyError.selector), refund);
    }

    function callSuccess(address refund) external payable {
        gateway.withBatch{value: msg.value}(abi.encodeWithSelector(this._success.selector, true, 1), refund);
    }
}

contract GatewayTestWithBatch is GatewayTest {
    IntegrationMock integration;

    function setUp() public override {
        super.setUp();
        integration = new IntegrationMock(gateway);
    }

    function testErrAlreadyBatching() public {
        vm.prank(ANY);
        vm.expectRevert(IGateway.AlreadyBatching.selector);
        integration.callNested(REFUND);
    }

    function testErrCallFailedWithEmptyRevert() public {
        vm.prank(ANY);
        vm.expectRevert(IGateway.CallFailedWithEmptyRevert.selector);
        integration.callEmptyError(REFUND);
    }

    function testWithCallback() public {
        vm.prank(ANY);
        vm.deal(ANY, 1234);
        integration.callSuccess{value: 1234}(REFUND);

        assertEq(integration.wasCalled(), true);
        assertEq(gateway.batcher(), address(0));
        assertEq(REFUND.balance, 1234);
    }
}
