// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth, IAuth} from "../../../src/misc/Auth.sol";
import {BytesLib} from "../../../src/misc/libraries/BytesLib.sol";
import {Recoverable, IRecoverable} from "../../../src/misc/Recoverable.sol";
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
    if (kind == MessageKind.WithPoolAFail) return 10;
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

// -----------------------------------------
//     GATEWAY EXTENSION
// -----------------------------------------

contract GatewayExt is Gateway {
    constructor(IRoot root_, IGasService gasService_, address deployer) Gateway(root_, gasService_, deployer) {}

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
}

// -----------------------------------------
//     GATEWAY TESTS
// -----------------------------------------

contract GatewayTest is Test {
    uint16 constant REMOTE_CENT_ID = 24;

    uint256 constant ADAPTER_ESTIMATE = 1 gwei;
    bytes32 constant ADAPTER_DATA = bytes32("adapter data");

    uint256 constant MESSAGE_GAS_LIMIT = 10.0 gwei;
    uint256 constant MAX_BATCH_GAS_LIMIT = 50.0 gwei;
    uint128 constant EXTRA_GAS_LIMIT = 1.0 gwei;

    IGasService gasService = IGasService(makeAddr("GasService"));
    IRoot root = IRoot(makeAddr("Root"));
    IAdapter adapter = IAdapter(makeAddr("Adapter"));

    MockProcessor processor = new MockProcessor();
    GatewayExt gateway = new GatewayExt(IRoot(address(root)), gasService, address(this));

    address immutable ANY = makeAddr("ANY");
    address immutable TRANSIENT_REFUND = makeAddr("TRANSIENT_REFUND");
    IRecoverable immutable POOL_REFUND = new MockPoolRefund(address(gateway));

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

    function setUp() public {
        gateway.file("adapter", address(adapter));
        gateway.file("processor", address(processor));

        _mockPause(false);
        _mockGasService();
    }

    function testConstructor() public view {
        assertEq(address(gateway.root()), address(root));
        assertEq(address(gateway.gasService()), address(gasService));

        (, IRecoverable refund) = gateway.subsidy(POOL_0);
        assertEq(address(refund), address(gateway));
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

contract GatewayTestReceive is GatewayTest {
    function testGatewayReceive() public {
        (bool success,) = address(gateway).call{value: 100}(new bytes(0));

        assertEq(success, true);

        (uint96 value,) = gateway.subsidy(POOL_0);
        assertEq(value, 100);

        assertEq(address(gateway).balance, 100);
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

    function testMessage() public {
        bytes memory batch = MessageKind.WithPool0.asBytes();

        vm.expectEmit();
        emit IGateway.ExecuteMessage(REMOTE_CENT_ID, batch);
        gateway.handle(REMOTE_CENT_ID, batch);

        assertEq(processor.processed(REMOTE_CENT_ID, 0), batch);
    }

    function testMessageFailed() public {
        bytes memory batch = MessageKind.WithPoolAFail.asBytes();

        vm.expectEmit();
        emit IGateway.FailMessage(REMOTE_CENT_ID, batch, abi.encodeWithSignature("HandleError()"));
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
        emit IGateway.ExecuteMessage(REMOTE_CENT_ID, batch);
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

contract GatewayTestSetExtraGasLimit is GatewayTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.setExtraGasLimit(0);
    }

    function testCorrectSetExtraGasLimit() public {
        gateway.setExtraGasLimit(EXTRA_GAS_LIMIT);
        assertEq(gateway.extraGasLimit(), EXTRA_GAS_LIMIT);
    }
}

contract GatewayTestSetRefundAddress is GatewayTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.setRefundAddress(POOL_A, POOL_REFUND);
    }

    function testSetRefundAddress() public {
        vm.expectEmit();
        emit IGateway.SetRefundAddress(POOL_A, POOL_REFUND);
        gateway.setRefundAddress(POOL_A, POOL_REFUND);

        (, IRecoverable refund) = gateway.subsidy(POOL_A);
        assertEq(address(refund), address(POOL_REFUND));
    }
}

contract GatewayTestSetSubsidizePool is GatewayTest {
    function testErrRefundAddressNotSet() public {
        vm.deal(ANY, 100);
        vm.prank(ANY);
        vm.expectRevert(IGateway.RefundAddressNotSet.selector);
        gateway.subsidizePool{value: 100}(POOL_A);
    }

    function testSetSubsidizePool() public {
        gateway.setRefundAddress(POOL_A, POOL_REFUND);

        vm.deal(ANY, 100);
        vm.prank(ANY);
        vm.expectEmit();
        emit IGateway.SubsidizePool(POOL_A, ANY, 100);
        gateway.subsidizePool{value: 100}(POOL_A);

        (uint96 value,) = gateway.subsidy(POOL_A);
        assertEq(value, 100);
    }
}

contract GatewayTestPayTransaction is GatewayTest {
    function testErrNotAuthorized() public {
        vm.deal(ANY, 100);
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.startTransactionPayment{value: 100}(TRANSIENT_REFUND);
    }

    function testPayTransaction() public {
        gateway.startTransactionPayment{value: 100}(TRANSIENT_REFUND);

        assertEq(gateway.transactionRefund(), TRANSIENT_REFUND);
        assertEq(gateway.fuel(), 100);
    }

    /// forge-config: default.isolate = true
    function testPayTransactionIsTransactional() public {
        gateway.startTransactionPayment{value: 100}(TRANSIENT_REFUND);

        assertEq(gateway.transactionRefund(), address(0));
        assertEq(gateway.fuel(), 0);
    }
}

contract GatewayTestStartBatching is GatewayTest {
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
        gateway.send(REMOTE_CENT_ID, new bytes(0));
    }

    function testErrPaused() public {
        _mockPause(true);
        vm.expectRevert(IGateway.Paused.selector);
        gateway.send(REMOTE_CENT_ID, new bytes(0));
    }

    function testErrEmptyMessage() public {
        vm.expectRevert(IGateway.EmptyMessage.selector);
        gateway.send(REMOTE_CENT_ID, new bytes(0));
    }

    function testErrExceedsMaxBatching() public {
        gateway.startBatching();
        uint256 maxMessages = MAX_BATCH_GAS_LIMIT / MESSAGE_GAS_LIMIT;

        for (uint256 i; i < maxMessages; i++) {
            gateway.send(REMOTE_CENT_ID, MessageKind.WithPoolA1.asBytes());
        }

        vm.expectRevert(IGateway.ExceedsMaxGasLimit.selector);
        gateway.send(REMOTE_CENT_ID, MessageKind.WithPoolA1.asBytes());
    }

    function testErrNotEnoughTransactionGas() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();

        uint256 payment = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE - 1;
        gateway.startTransactionPayment{value: payment}(TRANSIENT_REFUND);

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, TRANSIENT_REFUND);

        vm.expectRevert(IGateway.NotEnoughTransactionGas.selector);
        gateway.send(REMOTE_CENT_ID, message);
    }

    function testMessageWasBatched() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();

        gateway.startBatching();

        vm.expectEmit();
        emit IGateway.PrepareMessage(REMOTE_CENT_ID, POOL_A, message);
        gateway.send(REMOTE_CENT_ID, message);

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
        gateway.send(REMOTE_CENT_ID, message1);
        gateway.send(REMOTE_CENT_ID, message2);

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), MESSAGE_GAS_LIMIT * 2);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), abi.encodePacked(message1, message2));
        assertEq(gateway.batchLocatorsLength(), 1);
    }

    function testSecondMessageWasBatchedSamePoolDifferentChain() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1);
        gateway.send(REMOTE_CENT_ID + 1, message2);

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
        gateway.send(REMOTE_CENT_ID, message1);
        gateway.send(REMOTE_CENT_ID, message2);

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), MESSAGE_GAS_LIMIT);
        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_0), MESSAGE_GAS_LIMIT);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), message1);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_0), message2);
        assertEq(gateway.batchLocatorsLength(), 2);
    }

    function testSendMessageUnderpaid() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(message);

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, address(POOL_REFUND));

        vm.expectEmit();
        emit IGateway.PrepareMessage(REMOTE_CENT_ID, POOL_A, message);
        vm.expectEmit();
        emit IGateway.UnderpaidBatch(REMOTE_CENT_ID, message);
        gateway.send(REMOTE_CENT_ID, message);

        (uint128 counter, uint128 gasLimit) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(counter, 1);
        assertEq(gasLimit, MESSAGE_GAS_LIMIT);
    }

    function testSendMessageUnderpaidTwice() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(message);

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, address(POOL_REFUND));

        gateway.send(REMOTE_CENT_ID, message);
        gateway.send(REMOTE_CENT_ID, message);

        (uint128 counter, uint128 gasLimit) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(counter, 2);
        assertEq(gasLimit, MESSAGE_GAS_LIMIT);
    }

    function testSendMessageUsingSubsidizedPoolPayment() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();

        uint256 payment = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE + 1234;
        gateway.setRefundAddress(POOL_A, POOL_REFUND);
        gateway.subsidizePool{value: payment}(POOL_A);

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, address(POOL_REFUND));

        vm.expectEmit();
        emit IGateway.PrepareMessage(REMOTE_CENT_ID, POOL_A, message);
        gateway.send(REMOTE_CENT_ID, message);

        (uint256 value,) = gateway.subsidy(POOL_A);
        assertEq(value, 1234);
    }

    function testSendMessageUsingSubsidizedPoolPaymentAndPoolRefunding() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();

        /// Not enough payment
        uint256 payment = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE - 1;
        gateway.setRefundAddress(POOL_A, POOL_REFUND);
        gateway.subsidizePool{value: payment}(POOL_A);

        // The refund system will take this amount to perform the required payment
        vm.deal(address(POOL_REFUND), 1);

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, address(POOL_REFUND));

        vm.expectEmit();
        emit IGateway.SubsidizePool(POOL_A, address(POOL_REFUND), 1);
        gateway.send(REMOTE_CENT_ID, message);

        (uint256 value,) = gateway.subsidy(POOL_A);
        assertEq(value, 0);
    }

    function testSendMessageUsingTransactionPayment() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();

        uint256 payment = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE + 1234;
        gateway.startTransactionPayment{value: payment}(TRANSIENT_REFUND);

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, TRANSIENT_REFUND);

        vm.expectEmit();
        emit IGateway.PrepareMessage(REMOTE_CENT_ID, POOL_A, message);
        gateway.send(REMOTE_CENT_ID, message);
    }

    function testMessageWithExtraGasLimit() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();

        _mockAdapter(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT + EXTRA_GAS_LIMIT, TRANSIENT_REFUND);

        gateway.setExtraGasLimit(EXTRA_GAS_LIMIT);
        gateway.send(REMOTE_CENT_ID, message);
    }

    function testMessageBatchedWithExtraGasLimit() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();

        gateway.setExtraGasLimit(EXTRA_GAS_LIMIT);
        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message);

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), MESSAGE_GAS_LIMIT + EXTRA_GAS_LIMIT);
    }
}

contract GatewayTestEndBatching is GatewayTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.endBatching();
    }

    function testErrNoBatched() public {
        vm.expectRevert(IGateway.NoBatched.selector);
        gateway.endBatching();
    }

    function testSendTwoMessageBatching() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        bytes memory batch = bytes.concat(message1, message2);

        uint256 payment = MESSAGE_GAS_LIMIT * 2 + ADAPTER_ESTIMATE;
        gateway.setRefundAddress(POOL_A, POOL_REFUND);
        gateway.subsidizePool{value: payment}(POOL_A);

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1);
        gateway.send(REMOTE_CENT_ID, message2);

        _mockAdapter(REMOTE_CENT_ID, batch, MESSAGE_GAS_LIMIT * 2, address(POOL_REFUND));

        gateway.endBatching();

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), 0);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), new bytes(0));
        assertEq(gateway.batchLocatorsLength(), 0);
        assertEq(gateway.isBatching(), false);
    }

    function testSendTwoMessageBatchingDifferentChainSamePool() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();

        uint256 payment = (MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE) * 2;
        gateway.setRefundAddress(POOL_A, POOL_REFUND);
        gateway.subsidizePool{value: payment}(POOL_A);

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1);
        gateway.send(REMOTE_CENT_ID + 1, message2);

        _mockAdapter(REMOTE_CENT_ID, message1, MESSAGE_GAS_LIMIT, address(POOL_REFUND));
        _mockAdapter(REMOTE_CENT_ID + 1, message2, MESSAGE_GAS_LIMIT, address(POOL_REFUND));

        gateway.endBatching();

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

        uint256 payment = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE;
        gateway.setRefundAddress(POOL_A, POOL_REFUND);
        gateway.setRefundAddress(POOL_0, POOL_REFUND);
        gateway.subsidizePool{value: payment}(POOL_A);
        gateway.subsidizePool{value: payment}(POOL_0);

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1);
        gateway.send(REMOTE_CENT_ID, message2);

        _mockAdapter(REMOTE_CENT_ID, message1, MESSAGE_GAS_LIMIT, address(POOL_REFUND));
        _mockAdapter(REMOTE_CENT_ID, message2, MESSAGE_GAS_LIMIT, address(POOL_REFUND));

        gateway.endBatching();

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), 0);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), new bytes(0));
        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_0), 0);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_0), new bytes(0));
        assertEq(gateway.batchLocatorsLength(), 0);
        assertEq(gateway.isBatching(), false);
    }

    function testSendTwoMessageBatchingUsingTransactionPayment() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        bytes memory batch = bytes.concat(message1, message2);

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1);
        gateway.send(REMOTE_CENT_ID, message2);

        uint256 payment = MESSAGE_GAS_LIMIT * 2 + ADAPTER_ESTIMATE;
        gateway.startTransactionPayment{value: payment}(TRANSIENT_REFUND);

        _mockAdapter(REMOTE_CENT_ID, batch, MESSAGE_GAS_LIMIT * 2, TRANSIENT_REFUND);

        gateway.endBatching();
    }

    function testSendMessageUnderpaid() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        bytes memory batch = bytes.concat(message1, message2);
        bytes32 batchHash = keccak256(batch);

        gateway.setRefundAddress(POOL_A, POOL_REFUND);
        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1);
        gateway.send(REMOTE_CENT_ID, message2);

        _mockAdapter(REMOTE_CENT_ID, batch, MESSAGE_GAS_LIMIT * 2, address(POOL_REFUND));
        gateway.endBatching();

        (uint128 counter, uint128 gasLimit) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(counter, 1);
        assertEq(gasLimit, MESSAGE_GAS_LIMIT * 2);
    }
}

contract GatewayTestRepay is GatewayTest {
    function testErrPaused() public {
        _mockPause(true);
        vm.expectRevert(IGateway.Paused.selector);
        gateway.repay(REMOTE_CENT_ID, new bytes(0));
    }

    function testErrNotUnderpaidBatch() public {
        bytes memory batch = MessageKind.WithPoolA1.asBytes();

        vm.expectRevert(IGateway.NotUnderpaidBatch.selector);
        gateway.repay(REMOTE_CENT_ID, batch);
    }

    function testErrInsufficientFundsForRepayment() public {
        bytes memory batch = MessageKind.WithPoolA1.asBytes();
        gateway.setRefundAddress(POOL_A, POOL_REFUND);

        _mockAdapter(REMOTE_CENT_ID, batch, MESSAGE_GAS_LIMIT, address(POOL_REFUND));
        gateway.send(REMOTE_CENT_ID, batch);

        vm.expectRevert(IGateway.InsufficientFundsForRepayment.selector);
        gateway.repay(REMOTE_CENT_ID, batch);
    }

    function testCorrectRepay() public {
        bytes memory batch = MessageKind.WithPoolA1.asBytes();
        gateway.setRefundAddress(POOL_A, POOL_REFUND);

        _mockAdapter(REMOTE_CENT_ID, batch, MESSAGE_GAS_LIMIT, address(POOL_REFUND));
        gateway.send(REMOTE_CENT_ID, batch);

        uint256 payment = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE;
        vm.expectEmit();
        emit IGateway.RepayBatch(REMOTE_CENT_ID, batch);
        gateway.repay{value: payment}(REMOTE_CENT_ID, batch);
    }

    function testErrInsufficientFundsForRepaymentWithBatches() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        bytes memory batch = bytes.concat(message1, message2);
        gateway.setRefundAddress(POOL_A, POOL_REFUND);
        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1);
        gateway.send(REMOTE_CENT_ID, message2);

        _mockAdapter(REMOTE_CENT_ID, batch, MESSAGE_GAS_LIMIT * 2, address(POOL_REFUND));
        gateway.endBatching();

        // Expected: MESSAGE_GAS_LIMIT * 2 + ...
        uint256 payment = MESSAGE_GAS_LIMIT + ADAPTER_ESTIMATE;
        vm.expectRevert(IGateway.InsufficientFundsForRepayment.selector);
        gateway.repay{value: payment}(REMOTE_CENT_ID, batch);
    }

    function testCorrectRepayForBatches() public {
        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        bytes memory batch = bytes.concat(message1, message2);
        gateway.setRefundAddress(POOL_A, POOL_REFUND);
        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1);
        gateway.send(REMOTE_CENT_ID, message2);

        _mockAdapter(REMOTE_CENT_ID, batch, MESSAGE_GAS_LIMIT * 2, address(POOL_REFUND));
        gateway.endBatching();

        uint256 payment = MESSAGE_GAS_LIMIT * 2 + ADAPTER_ESTIMATE;

        vm.expectEmit();
        emit IGateway.RepayBatch(REMOTE_CENT_ID, batch);
        gateway.repay{value: payment}(REMOTE_CENT_ID, batch);
    }
}

contract GatewayTestAddUnpaidMessage is GatewayTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.addUnpaidMessage(REMOTE_CENT_ID, bytes(""));
    }

    function testCorrectAddUnpaidMessage() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(message);

        vm.expectEmit();
        emit IGateway.UnderpaidBatch(REMOTE_CENT_ID, message);
        gateway.addUnpaidMessage(REMOTE_CENT_ID, message);

        (uint128 counter, uint128 gasLimit) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(counter, 1);
        assertEq(gasLimit, MESSAGE_GAS_LIMIT);
    }

    function testCorrectAddUnpaidMessageTwice() public {
        bytes memory message = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(message);

        gateway.addUnpaidMessage(REMOTE_CENT_ID, message);
        gateway.addUnpaidMessage(REMOTE_CENT_ID, message);

        (uint128 counter, uint128 gasLimit) = gateway.underpaid(REMOTE_CENT_ID, batchHash);
        assertEq(counter, 2);
        assertEq(gasLimit, MESSAGE_GAS_LIMIT);
    }
}
