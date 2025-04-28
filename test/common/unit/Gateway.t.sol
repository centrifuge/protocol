// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {Auth, IAuth} from "src/misc/Auth.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {Recoverable, IRecoverable} from "src/misc/Recoverable.sol";

import {Gateway, IRoot, IGasService, IGateway} from "src/common/Gateway.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {TransientArrayLib} from "src/misc/libraries/TransientArrayLib.sol";
import {TransientBytesLib} from "src/misc/libraries/TransientBytesLib.sol";
import {TransientStorageLib} from "src/misc/libraries/TransientStorageLib.sol";

import {IMessageProperties} from "src/common/interfaces/IMessageProperties.sol";
import {IMessageProcessor} from "src/common/interfaces/IMessageProcessor.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {MessageProofLib} from "src/common/libraries/MessageProofLib.sol";

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

    function isMessageRecovery(bytes calldata message) external pure returns (bool) {
        return message.toUint8(0) == uint8(MessageKind.Recovery);
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
    constructor(uint16 localCentrifugeId_, IRoot root_, IGasService gasService_, address deployer)
        Gateway(localCentrifugeId_, root_, gasService_, deployer)
    {}

    function activeAdapters(uint16 centrifugeId, IAdapter adapter) public view returns (IGateway.Adapter memory) {
        return _activeAdapters[centrifugeId][adapter];
    }

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
    uint16 constant LOCAL_CENT_ID = 23;
    uint16 constant REMOTE_CENT_ID = 24;

    uint256 constant ADAPTER_ESTIMATE_1 = 1.5 gwei;
    uint256 constant ADAPTER_ESTIMATE_2 = 1 gwei;
    uint256 constant ADAPTER_ESTIMATE_3 = 0.5 gwei;

    bytes32 constant ADAPTER_DATA_1 = bytes32("data1");
    bytes32 constant ADAPTER_DATA_2 = bytes32("data2");
    bytes32 constant ADAPTER_DATA_3 = bytes32("data3");

    uint256 constant MESSAGE_GAS_LIMIT = 10.0 gwei;
    uint256 constant MAX_BATCH_SIZE = 50.0 gwei;

    bool constant ADAPTER_PAID = true;

    IGasService gasService = IGasService(makeAddr("GasService"));
    IRoot root = IRoot(makeAddr("Root"));
    IAdapter batchAdapter = IAdapter(makeAddr("BatchAdapter"));
    IAdapter proofAdapter1 = IAdapter(makeAddr("ProofAdapter1"));
    IAdapter proofAdapter2 = IAdapter(makeAddr("ProofAdapter2"));
    IAdapter[] oneAdapter;
    IAdapter[] threeAdapters;

    MockProcessor processor = new MockProcessor();
    GatewayExt gateway = new GatewayExt(LOCAL_CENT_ID, IRoot(address(root)), gasService, address(this));

    address immutable ANY = makeAddr("ANY");
    address immutable TRANSIENT_REFUND = makeAddr("TRANSIENT_REFUND");
    IRecoverable immutable POOL_REFUND = new MockPoolRefund(address(gateway));

    function _mockAdapter(
        IAdapter adapter,
        uint16 centrifugeId,
        bytes memory message,
        uint256 gasLimit,
        address refund,
        uint256 estimate,
        bytes32 adapterData
    ) private {
        vm.mockCall(
            address(adapter),
            abi.encodeWithSelector(IAdapter.estimate.selector, centrifugeId, message, gasLimit),
            abi.encode(gasLimit + estimate)
        );

        vm.mockCall(
            address(adapter),
            gasLimit + estimate,
            abi.encodeWithSelector(IAdapter.send.selector, centrifugeId, message, gasLimit, refund),
            abi.encode(adapterData)
        );
    }

    function _mockAdapters(uint16 centrifugeId, bytes memory message, uint256 gasLimit, address refund) internal {
        _mockAdapter(batchAdapter, centrifugeId, message, gasLimit, refund, ADAPTER_ESTIMATE_1, ADAPTER_DATA_1);

        bytes memory proof = MessageProofLib.serializeMessageProof(keccak256(message));
        _mockAdapter(proofAdapter1, centrifugeId, proof, gasLimit, refund, ADAPTER_ESTIMATE_2, ADAPTER_DATA_2);
        _mockAdapter(proofAdapter2, centrifugeId, proof, gasLimit, refund, ADAPTER_ESTIMATE_3, ADAPTER_DATA_3);
    }

    function _mockGasService() internal {
        vm.mockCall(
            address(gasService), abi.encodeWithSelector(IGasService.gasLimit.selector), abi.encode(MESSAGE_GAS_LIMIT)
        );
        vm.mockCall(
            address(gasService), abi.encodeWithSelector(IGasService.maxBatchSize.selector), abi.encode(MAX_BATCH_SIZE)
        );
    }

    function _mockPause(bool isPaused) internal {
        vm.mockCall(address(root), abi.encodeWithSelector(IRoot.paused.selector), abi.encode(isPaused));
    }

    function assertVotes(bytes memory message, uint16 r1, uint16 r2, uint16 r3) internal view {
        uint16[8] memory votes = gateway.votes(REMOTE_CENT_ID, keccak256(message));
        assertEq(votes[0], r1);
        assertEq(votes[1], r2);
        assertEq(votes[2], r3);
    }

    function setUp() public {
        oneAdapter.push(batchAdapter);
        threeAdapters.push(batchAdapter);
        threeAdapters.push(proofAdapter1);
        threeAdapters.push(proofAdapter2);
        gateway.file("processor", address(processor));

        _mockPause(false);
        _mockGasService();
    }

    function testConstructor() public view {
        assertEq(gateway.localCentrifugeId(), LOCAL_CENT_ID);
        assertEq(address(gateway.root()), address(root));
        assertEq(address(gateway.gasService()), address(gasService));

        (, IRecoverable refund) = gateway.subsidy(POOL_0);
        assertEq(address(refund), address(gateway));

        assertEq(gateway.wards(address(this)), 1);
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
    }
}

contract GatewayTestFileAdapters is GatewayTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.file("unknown", REMOTE_CENT_ID, new IAdapter[](0));
    }

    function testErrFileUnrecognizedParam() public {
        vm.expectRevert(IGateway.FileUnrecognizedParam.selector);
        gateway.file("unknown", REMOTE_CENT_ID, new IAdapter[](0));
    }

    function testErrEmptyAdapterFile() public {
        vm.expectRevert(IGateway.EmptyAdapterSet.selector);
        gateway.file("adapters", REMOTE_CENT_ID, new IAdapter[](0));
    }

    function testErrExceedsMax() public {
        IAdapter[] memory tooMuchAdapters = new IAdapter[](gateway.MAX_ADAPTER_COUNT() + 1);
        vm.expectRevert(IGateway.ExceedsMax.selector);
        gateway.file("adapters", REMOTE_CENT_ID, tooMuchAdapters);
    }

    function testErrNoDuplicatedAllowed() public {
        IAdapter[] memory duplicatedAdapters = new IAdapter[](2);
        duplicatedAdapters[0] = IAdapter(address(10));
        duplicatedAdapters[1] = IAdapter(address(10));

        vm.expectRevert(IGateway.NoDuplicatesAllowed.selector);
        gateway.file("adapters", REMOTE_CENT_ID, duplicatedAdapters);
    }

    function testGatewayFileAdapters() public {
        vm.expectEmit();
        emit IGateway.File("adapters", REMOTE_CENT_ID, threeAdapters);
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        assertEq(gateway.activeSessionId(REMOTE_CENT_ID), 0);
        assertEq(gateway.quorum(REMOTE_CENT_ID), threeAdapters.length);

        for (uint256 i; i < threeAdapters.length; i++) {
            IGateway.Adapter memory adapter = gateway.activeAdapters(REMOTE_CENT_ID, threeAdapters[i]);

            assertEq(adapter.id, i + 1);
            assertEq(adapter.quorum, threeAdapters.length);
            assertEq(adapter.activeSessionId, 0);
            assertEq(address(gateway.adapters(REMOTE_CENT_ID, i)), address(threeAdapters[i]));
        }
    }

    function testGatewayFileAdaptersAdvanceSession() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);
        assertEq(gateway.activeSessionId(REMOTE_CENT_ID), 0);

        // Using another chain uses a different active session counter
        gateway.file("adapters", LOCAL_CENT_ID, threeAdapters);
        assertEq(gateway.activeSessionId(LOCAL_CENT_ID), 0);

        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);
        assertEq(gateway.activeSessionId(REMOTE_CENT_ID), 1);
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

    function testErrInvalidAdapter() public {
        vm.expectRevert(IGateway.InvalidAdapter.selector);
        gateway.handle(REMOTE_CENT_ID, new bytes(0));
    }

    function testErrNonProofAdapter() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        vm.prank(address(batchAdapter));
        vm.expectRevert(IGateway.NonProofAdapter.selector);
        gateway.handle(REMOTE_CENT_ID, MessageProofLib.serializeMessageProof(bytes32("1")));
    }

    function testErrNonProofAdapterWithOneAdapter() public {
        gateway.file("adapters", REMOTE_CENT_ID, oneAdapter);

        vm.prank(address(batchAdapter));
        vm.expectRevert(IGateway.NonProofAdapter.selector);
        gateway.handle(REMOTE_CENT_ID, MessageProofLib.serializeMessageProof(bytes32("1")));
    }

    function testErrNonBatchAdapter() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        vm.prank(address(proofAdapter1));
        vm.expectRevert(IGateway.NonBatchAdapter.selector);
        gateway.handle(REMOTE_CENT_ID, MessageKind.WithPool0.asBytes());
    }

    function testErrEmptyMessage() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        vm.prank(address(batchAdapter));
        vm.expectRevert(BytesLib.SliceOutOfBounds.selector);
        gateway.handle(REMOTE_CENT_ID, new bytes(0));
    }

    function testMessage() public {
        gateway.file("adapters", REMOTE_CENT_ID, oneAdapter);

        bytes memory batch = MessageKind.WithPool0.asBytes();

        vm.prank(address(batchAdapter));
        vm.expectEmit();
        emit IGateway.ExecuteMessage(REMOTE_CENT_ID, batch);
        gateway.handle(REMOTE_CENT_ID, batch);

        assertEq(processor.processed(REMOTE_CENT_ID, 0), batch);
    }

    function testMessageFailed() public {
        gateway.file("adapters", REMOTE_CENT_ID, oneAdapter);

        bytes memory batch = MessageKind.WithPoolAFail.asBytes();

        vm.prank(address(batchAdapter));
        vm.expectEmit();
        emit IGateway.FailMessage(REMOTE_CENT_ID, batch, abi.encodeWithSignature("HandleError()"));
        gateway.handle(REMOTE_CENT_ID, batch);

        assertEq(processor.count(REMOTE_CENT_ID), 0);
        assertEq(gateway.failedMessages(REMOTE_CENT_ID, keccak256(batch)), 1);
    }

    function testMessageAndProofs() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory batch = MessageKind.WithPool0.asBytes();
        bytes32 batchHash = keccak256(batch);
        bytes memory proof = MessageProofLib.serializeMessageProof(batchHash);
        bytes32 batchId = keccak256(abi.encodePacked(REMOTE_CENT_ID, LOCAL_CENT_ID, batchHash));
        bytes32 proofId = keccak256(abi.encodePacked(REMOTE_CENT_ID, LOCAL_CENT_ID, batchHash));

        vm.prank(address(batchAdapter));
        vm.expectEmit();
        emit IGateway.HandleBatch(REMOTE_CENT_ID, batchId, batch, batchAdapter);
        gateway.handle(REMOTE_CENT_ID, batch);
        assertEq(processor.count(REMOTE_CENT_ID), 0);
        assertVotes(batch, 1, 0, 0);

        vm.prank(address(proofAdapter1));
        vm.expectEmit();
        emit IGateway.HandleProof(REMOTE_CENT_ID, proofId, batchHash, proofAdapter1);
        gateway.handle(REMOTE_CENT_ID, proof);
        assertEq(processor.count(REMOTE_CENT_ID), 0);
        assertVotes(batch, 1, 1, 0);

        vm.prank(address(proofAdapter2));
        vm.expectEmit();
        emit IGateway.HandleProof(REMOTE_CENT_ID, proofId, batchHash, proofAdapter2);
        gateway.handle(REMOTE_CENT_ID, proof);
        assertEq(processor.count(REMOTE_CENT_ID), 1);
        assertEq(processor.processed(REMOTE_CENT_ID, 0), batch);
        assertVotes(batch, 0, 0, 0);
    }

    function testSameMessageAndProofs() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory batch = MessageKind.WithPool0.asBytes();
        bytes memory proof = MessageProofLib.serializeMessageProof(keccak256(batch));

        vm.prank(address(batchAdapter));
        gateway.handle(REMOTE_CENT_ID, batch);
        vm.prank(address(proofAdapter1));
        gateway.handle(REMOTE_CENT_ID, proof);
        vm.prank(address(proofAdapter2));
        gateway.handle(REMOTE_CENT_ID, proof);

        vm.prank(address(batchAdapter));
        gateway.handle(REMOTE_CENT_ID, batch);
        assertEq(processor.count(REMOTE_CENT_ID), 1);
        assertVotes(batch, 1, 0, 0);

        vm.prank(address(proofAdapter1));
        gateway.handle(REMOTE_CENT_ID, proof);
        assertEq(processor.count(REMOTE_CENT_ID), 1);
        assertVotes(batch, 1, 1, 0);

        vm.prank(address(proofAdapter2));
        gateway.handle(REMOTE_CENT_ID, proof);
        assertEq(processor.count(REMOTE_CENT_ID), 2);
        assertEq(processor.processed(REMOTE_CENT_ID, 1), batch);
        assertVotes(batch, 0, 0, 0);
    }

    function testOtherMessageAndProofs() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory batch = MessageKind.WithPool0.asBytes();
        bytes memory proof = MessageProofLib.serializeMessageProof(keccak256(batch));

        vm.prank(address(batchAdapter));
        gateway.handle(REMOTE_CENT_ID, batch);
        vm.prank(address(proofAdapter1));
        gateway.handle(REMOTE_CENT_ID, proof);
        vm.prank(address(proofAdapter2));
        gateway.handle(REMOTE_CENT_ID, proof);

        bytes memory batch2 = MessageKind.WithPoolA1.asBytes();
        bytes memory proof2 = MessageProofLib.serializeMessageProof(keccak256(batch2));

        vm.prank(address(batchAdapter));
        gateway.handle(REMOTE_CENT_ID, batch2);
        assertEq(processor.count(REMOTE_CENT_ID), 1);
        assertVotes(batch2, 1, 0, 0);

        vm.prank(address(proofAdapter1));
        gateway.handle(REMOTE_CENT_ID, proof2);
        assertEq(processor.count(REMOTE_CENT_ID), 1);
        assertVotes(batch2, 1, 1, 0);

        vm.prank(address(proofAdapter2));
        gateway.handle(REMOTE_CENT_ID, proof2);
        assertEq(processor.count(REMOTE_CENT_ID), 2);
        assertEq(processor.processed(REMOTE_CENT_ID, 1), batch2);
        assertVotes(batch2, 0, 0, 0);
    }

    function testMessageAfterProofs() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory batch = MessageKind.WithPool0.asBytes();
        bytes memory proof = MessageProofLib.serializeMessageProof(keccak256(batch));

        vm.prank(address(proofAdapter1));
        gateway.handle(REMOTE_CENT_ID, proof);
        assertEq(processor.count(REMOTE_CENT_ID), 0);
        assertVotes(batch, 0, 1, 0);

        vm.prank(address(proofAdapter2));
        gateway.handle(REMOTE_CENT_ID, proof);
        assertEq(processor.count(REMOTE_CENT_ID), 0);
        assertVotes(batch, 0, 1, 1);

        vm.prank(address(batchAdapter));
        gateway.handle(REMOTE_CENT_ID, batch);
        assertEq(processor.count(REMOTE_CENT_ID), 1);
        assertVotes(batch, 0, 0, 0);
    }

    function testOneFasterAdapter() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory batch = MessageKind.WithPool0.asBytes();
        bytes memory proof = MessageProofLib.serializeMessageProof(keccak256(batch));

        vm.prank(address(batchAdapter));
        gateway.handle(REMOTE_CENT_ID, batch);
        vm.prank(address(batchAdapter));
        gateway.handle(REMOTE_CENT_ID, batch);
        assertEq(processor.count(REMOTE_CENT_ID), 0);
        assertVotes(batch, 2, 0, 0);

        vm.prank(address(proofAdapter1));
        gateway.handle(REMOTE_CENT_ID, proof);
        assertEq(processor.count(REMOTE_CENT_ID), 0);
        assertVotes(batch, 2, 1, 0);

        vm.prank(address(proofAdapter2));
        gateway.handle(REMOTE_CENT_ID, proof);
        assertEq(processor.count(REMOTE_CENT_ID), 1);
        assertVotes(batch, 1, 0, 0);

        vm.prank(address(proofAdapter1));
        gateway.handle(REMOTE_CENT_ID, proof);
        assertEq(processor.count(REMOTE_CENT_ID), 1);
        assertVotes(batch, 1, 1, 0);

        vm.prank(address(proofAdapter2));
        gateway.handle(REMOTE_CENT_ID, proof);
        assertEq(processor.count(REMOTE_CENT_ID), 2);
        assertVotes(batch, 0, 0, 0);
    }

    function testVotesAfterNewSession() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory batch = MessageKind.WithPool0.asBytes();
        bytes memory proof = MessageProofLib.serializeMessageProof(keccak256(batch));

        vm.prank(address(batchAdapter));
        gateway.handle(REMOTE_CENT_ID, batch);
        vm.prank(address(proofAdapter1));
        gateway.handle(REMOTE_CENT_ID, proof);

        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        vm.prank(address(proofAdapter2));
        gateway.handle(REMOTE_CENT_ID, proof);
        assertEq(processor.count(REMOTE_CENT_ID), 0);
        assertVotes(batch, 0, 0, 1);
    }

    function testBatchProcessing() public {
        gateway.file("adapters", REMOTE_CENT_ID, oneAdapter);

        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        bytes memory batch = abi.encodePacked(message1, message2);

        vm.prank(address(batchAdapter));
        gateway.handle(REMOTE_CENT_ID, batch);

        assertEq(processor.count(REMOTE_CENT_ID), 2);
        assertEq(processor.processed(REMOTE_CENT_ID, 0), message1);
        assertEq(processor.processed(REMOTE_CENT_ID, 1), message2);
    }

    function testBatchWithFailingMessages() public {
        gateway.file("adapters", REMOTE_CENT_ID, oneAdapter);

        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolAFail.asBytes();
        bytes memory message3 = MessageKind.WithPoolA2.asBytes();
        bytes memory batch = abi.encodePacked(message1, message2, message3);

        vm.prank(address(batchAdapter));
        gateway.handle(REMOTE_CENT_ID, batch);

        assertEq(processor.count(REMOTE_CENT_ID), 2);
        assertEq(processor.processed(REMOTE_CENT_ID, 0), message1);
        assertEq(processor.processed(REMOTE_CENT_ID, 1), message3);

        assertEq(gateway.failedMessages(REMOTE_CENT_ID, keccak256(message2)), 1);
    }

    function testMultipleSameFailingMessages() public {
        gateway.file("adapters", REMOTE_CENT_ID, oneAdapter);

        bytes memory batch = MessageKind.WithPoolAFail.asBytes();

        vm.prank(address(batchAdapter));
        gateway.handle(REMOTE_CENT_ID, batch);
        vm.prank(address(batchAdapter));
        gateway.handle(REMOTE_CENT_ID, batch);

        assertEq(gateway.failedMessages(REMOTE_CENT_ID, keccak256(batch)), 2);
    }

    function testBatchWithMultipleSameFailingMessages() public {
        gateway.file("adapters", REMOTE_CENT_ID, oneAdapter);

        bytes memory message = MessageKind.WithPoolAFail.asBytes();
        bytes memory batch = abi.encodePacked(message, message);

        vm.prank(address(batchAdapter));
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
        gateway.file("adapters", REMOTE_CENT_ID, oneAdapter);

        bytes memory batch = MessageKind.WithPoolAFail.asBytes();

        vm.prank(address(batchAdapter));
        gateway.handle(REMOTE_CENT_ID, batch);

        processor.disableFailure();

        vm.prank(ANY);
        emit IGateway.ExecuteMessage(REMOTE_CENT_ID, batch);
        gateway.retry(REMOTE_CENT_ID, batch);

        assertEq(gateway.failedMessages(REMOTE_CENT_ID, keccak256(batch)), 0);
        assertEq(processor.processed(REMOTE_CENT_ID, 0), batch);
    }

    function testRecoverMultipleFailingMessage() public {
        gateway.file("adapters", REMOTE_CENT_ID, oneAdapter);

        bytes memory batch = MessageKind.WithPoolAFail.asBytes();

        vm.prank(address(batchAdapter));
        gateway.handle(REMOTE_CENT_ID, batch);
        vm.prank(address(batchAdapter));
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

contract GatewayTestInitiateRecovery is GatewayTest {
    bytes32 constant BATCH_HASH = bytes32("1");

    function testErrInvalidAdapter() public {
        vm.expectRevert(IGateway.InvalidAdapter.selector);
        gateway.initiateRecovery(REMOTE_CENT_ID, batchAdapter, BATCH_HASH);
    }

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.initiateRecovery(REMOTE_CENT_ID, batchAdapter, BATCH_HASH);
    }

    function testInitiateRecovery() public {
        gateway.file("adapters", REMOTE_CENT_ID, oneAdapter);

        vm.expectEmit();
        emit IGateway.InitiateRecovery(REMOTE_CENT_ID, BATCH_HASH, batchAdapter);
        gateway.initiateRecovery(REMOTE_CENT_ID, batchAdapter, BATCH_HASH);

        assertEq(
            gateway.recoveries(REMOTE_CENT_ID, batchAdapter, BATCH_HASH),
            block.timestamp + gateway.RECOVERY_CHALLENGE_PERIOD()
        );
    }
}

contract GatewayTestDisputeRecovery is GatewayTest {
    bytes32 constant BATCH_HASH = bytes32("1");

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.initiateRecovery(REMOTE_CENT_ID, batchAdapter, BATCH_HASH);
    }

    function testDisputeRecovery() public {
        gateway.file("adapters", REMOTE_CENT_ID, oneAdapter);

        vm.expectEmit();
        emit IGateway.DisputeRecovery(REMOTE_CENT_ID, BATCH_HASH, batchAdapter);
        gateway.disputeRecovery(REMOTE_CENT_ID, batchAdapter, BATCH_HASH);

        assertEq(gateway.recoveries(REMOTE_CENT_ID, batchAdapter, BATCH_HASH), 0);
    }
}

contract GatewayTestExecuteRecovery is GatewayTest {
    function testErrRecoveryNotInitiated() public {
        vm.expectRevert(IGateway.RecoveryNotInitiated.selector);
        gateway.executeRecovery(REMOTE_CENT_ID, batchAdapter, bytes(""));
    }

    function testErrRecoveryChallengePeriodNotEnded() public {
        gateway.file("adapters", REMOTE_CENT_ID, oneAdapter);

        bytes memory batch = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(batch);

        gateway.initiateRecovery(REMOTE_CENT_ID, batchAdapter, batchHash);

        vm.prank(ANY);
        vm.expectRevert(IGateway.RecoveryChallengePeriodNotEnded.selector);
        gateway.executeRecovery(REMOTE_CENT_ID, batchAdapter, batch);
    }

    function testErrRecoveryRecovered() public {
        gateway.file("adapters", REMOTE_CENT_ID, oneAdapter);

        bytes memory batch = MessageKind.Recovery.asBytes();
        bytes32 batchHash = keccak256(batch);

        gateway.initiateRecovery(REMOTE_CENT_ID, batchAdapter, batchHash);

        vm.warp(gateway.RECOVERY_CHALLENGE_PERIOD() + 1);

        vm.prank(ANY);
        vm.expectRevert(IGateway.RecoveryPayloadRecovered.selector);
        gateway.executeRecovery(REMOTE_CENT_ID, batchAdapter, batch);
    }

    function testExecuteRecovery() public {
        gateway.file("adapters", REMOTE_CENT_ID, oneAdapter);

        bytes memory batch = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(batch);

        gateway.initiateRecovery(REMOTE_CENT_ID, batchAdapter, batchHash);

        vm.warp(gateway.RECOVERY_CHALLENGE_PERIOD() + 1);

        vm.prank(ANY);
        emit IGateway.ExecuteRecovery(REMOTE_CENT_ID, batch, batchAdapter);
        gateway.executeRecovery(REMOTE_CENT_ID, batchAdapter, batch);

        assertEq(processor.processed(REMOTE_CENT_ID, 0), batch);
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
        gateway.payTransaction{value: 100}(TRANSIENT_REFUND);
    }

    function testPayTransaction() public {
        gateway.payTransaction{value: 100}(TRANSIENT_REFUND);

        assertEq(gateway.transactionRefund(), TRANSIENT_REFUND);
        assertEq(gateway.fuel(), 100);
    }

    /// forge-config: default.isolate = true
    function testPayTransactionIsTransactional() public {
        gateway.payTransaction{value: 100}(TRANSIENT_REFUND);

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

    function testErrEmptyAdapterSet() public {
        vm.expectRevert(IGateway.EmptyAdapterSet.selector);
        gateway.send(REMOTE_CENT_ID, MessageKind.WithPoolA1.asBytes());
    }

    function testErrExceedsMaxBatching() public {
        gateway.startBatching();
        uint256 maxMessages = MAX_BATCH_SIZE / MESSAGE_GAS_LIMIT;

        for (uint256 i; i < maxMessages; i++) {
            gateway.send(REMOTE_CENT_ID, MessageKind.WithPoolA1.asBytes());
        }

        vm.expectRevert(IGateway.ExceedsMaxBatchSize.selector);
        gateway.send(REMOTE_CENT_ID, MessageKind.WithPoolA1.asBytes());
    }

    function testErrNotEnoughTransactionGas() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory message = MessageKind.WithPoolA1.asBytes();

        uint256 payment = MESSAGE_GAS_LIMIT * 3 + ADAPTER_ESTIMATE_1 + ADAPTER_ESTIMATE_2 + ADAPTER_ESTIMATE_3 - 1;
        gateway.payTransaction{value: payment}(TRANSIENT_REFUND);

        _mockAdapters(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, TRANSIENT_REFUND);

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

    function testSendMessageUsingDelayPayment() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory message = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(message);
        bytes32 batchId = keccak256(abi.encodePacked(LOCAL_CENT_ID, REMOTE_CENT_ID, batchHash));
        gateway.setRefundAddress(POOL_A, POOL_REFUND);

        vm.expectRevert(IGateway.NotUnderpaidBatch.selector);
        gateway.repay(REMOTE_CENT_ID, message);

        _mockAdapters(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, address(POOL_REFUND));

        vm.expectEmit();
        emit IGateway.PrepareMessage(REMOTE_CENT_ID, POOL_A, message);
        vm.expectEmit();
        emit IGateway.UnderpaidBatch(REMOTE_CENT_ID, message);
        gateway.send(REMOTE_CENT_ID, message);

        vm.expectRevert(IGateway.InsufficientFundsForRepayment.selector);
        gateway.repay(REMOTE_CENT_ID, message);

        uint256 payment = MESSAGE_GAS_LIMIT * 3 + ADAPTER_ESTIMATE_1 + ADAPTER_ESTIMATE_2 + ADAPTER_ESTIMATE_3;
        _mockAdapters(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, address(POOL_REFUND));

        vm.expectEmit();
        emit IGateway.SendBatch(REMOTE_CENT_ID, batchId, message, batchAdapter, ADAPTER_DATA_1, address(POOL_REFUND));
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID, batchId, batchHash, proofAdapter1, ADAPTER_DATA_2);
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID, batchId, batchHash, proofAdapter2, ADAPTER_DATA_3);
        vm.expectEmit();
        emit IGateway.RepayBatch(REMOTE_CENT_ID, message);
        gateway.repay{value: payment}(REMOTE_CENT_ID, message);
    }

    function testSendMessageUsingSubsidizedPoolPayment() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory message = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(message);
        bytes32 batchId = keccak256(abi.encodePacked(LOCAL_CENT_ID, REMOTE_CENT_ID, batchHash));

        uint256 payment = MESSAGE_GAS_LIMIT * 3 + ADAPTER_ESTIMATE_1 + ADAPTER_ESTIMATE_2 + ADAPTER_ESTIMATE_3 + 1234;
        gateway.setRefundAddress(POOL_A, POOL_REFUND);
        gateway.subsidizePool{value: payment}(POOL_A);

        _mockAdapters(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, address(POOL_REFUND));

        vm.expectEmit();
        emit IGateway.PrepareMessage(REMOTE_CENT_ID, POOL_A, message);
        vm.expectEmit();
        emit IGateway.SendBatch(REMOTE_CENT_ID, batchId, message, batchAdapter, ADAPTER_DATA_1, address(POOL_REFUND));
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID, batchId, batchHash, proofAdapter1, ADAPTER_DATA_2);
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID, batchId, batchHash, proofAdapter2, ADAPTER_DATA_3);
        gateway.send(REMOTE_CENT_ID, message);

        (uint256 value,) = gateway.subsidy(POOL_A);
        assertEq(value, 1234);
    }

    function testSendMessageUsingSubsidizedPoolPaymentAndPoolRefunding() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory message = MessageKind.WithPoolA1.asBytes();

        /// Not enough payment, the payment of the third message will be refunded
        uint256 payment = MESSAGE_GAS_LIMIT * 3 + ADAPTER_ESTIMATE_1 + ADAPTER_ESTIMATE_2 + ADAPTER_ESTIMATE_3 - 1;
        gateway.setRefundAddress(POOL_A, POOL_REFUND);
        gateway.subsidizePool{value: payment}(POOL_A);

        // The refund system will take this amount to pay the last message
        vm.deal(address(POOL_REFUND), 1);

        _mockAdapters(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, address(POOL_REFUND));

        vm.expectEmit();
        emit IGateway.SubsidizePool(POOL_A, address(POOL_REFUND), 1);
        gateway.send(REMOTE_CENT_ID, message);

        (uint256 value,) = gateway.subsidy(POOL_A);
        assertEq(value, 0);
    }

    function testSendMessageUsingTransactionPayment() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory message = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash = keccak256(message);
        bytes32 batchId = keccak256(abi.encodePacked(LOCAL_CENT_ID, REMOTE_CENT_ID, batchHash));

        uint256 payment = MESSAGE_GAS_LIMIT * 3 + ADAPTER_ESTIMATE_1 + ADAPTER_ESTIMATE_2 + ADAPTER_ESTIMATE_3 + 1234;
        gateway.payTransaction{value: payment}(TRANSIENT_REFUND);

        _mockAdapters(REMOTE_CENT_ID, message, MESSAGE_GAS_LIMIT, TRANSIENT_REFUND);

        vm.expectEmit();
        emit IGateway.PrepareMessage(REMOTE_CENT_ID, POOL_A, message);
        vm.expectEmit();
        emit IGateway.SendBatch(REMOTE_CENT_ID, batchId, message, batchAdapter, ADAPTER_DATA_1, TRANSIENT_REFUND);
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID, batchId, batchHash, proofAdapter1, ADAPTER_DATA_2);
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID, batchId, batchHash, proofAdapter2, ADAPTER_DATA_3);
        gateway.send(REMOTE_CENT_ID, message);

        assertEq(TRANSIENT_REFUND.balance, 1234);
        assertEq(gateway.fuel(), 0);
        assertEq(gateway.transactionRefund(), address(0));
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
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        bytes memory batch = bytes.concat(message1, message2);
        bytes32 batchHash = keccak256(batch);
        bytes32 batchId = keccak256(abi.encodePacked(LOCAL_CENT_ID, REMOTE_CENT_ID, batchHash));

        uint256 payment = MESSAGE_GAS_LIMIT * 3 * 2 + ADAPTER_ESTIMATE_1 + ADAPTER_ESTIMATE_2 + ADAPTER_ESTIMATE_3;
        gateway.setRefundAddress(POOL_A, POOL_REFUND);
        gateway.subsidizePool{value: payment}(POOL_A);

        _mockAdapters(REMOTE_CENT_ID, message1, MESSAGE_GAS_LIMIT, address(POOL_REFUND));

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1);
        gateway.send(REMOTE_CENT_ID, message2);

        _mockAdapters(REMOTE_CENT_ID, batch, MESSAGE_GAS_LIMIT * 2, address(POOL_REFUND));

        vm.expectEmit();
        emit IGateway.SendBatch(REMOTE_CENT_ID, batchId, batch, batchAdapter, ADAPTER_DATA_1, address(POOL_REFUND));
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID, batchId, batchHash, proofAdapter1, ADAPTER_DATA_2);
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID, batchId, batchHash, proofAdapter2, ADAPTER_DATA_3);
        gateway.endBatching();

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), 0);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), new bytes(0));
        assertEq(gateway.batchLocatorsLength(), 0);
        assertEq(gateway.isBatching(), false);
    }

    function testSendTwoMessageBatchingDifferentChainSamePool() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);
        gateway.file("adapters", REMOTE_CENT_ID + 1, threeAdapters);

        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        bytes32 batchHash1 = keccak256(message1);
        bytes32 batchHash2 = keccak256(message2);
        bytes32 batchId1 = keccak256(abi.encodePacked(LOCAL_CENT_ID, REMOTE_CENT_ID, batchHash1));
        bytes32 batchId2 = keccak256(abi.encodePacked(LOCAL_CENT_ID, REMOTE_CENT_ID + 1, batchHash2));

        uint256 payment =
            MESSAGE_GAS_LIMIT * 3 * 2 + ADAPTER_ESTIMATE_1 * 2 + ADAPTER_ESTIMATE_2 * 2 + ADAPTER_ESTIMATE_3 * 2;
        gateway.setRefundAddress(POOL_A, POOL_REFUND);
        gateway.subsidizePool{value: payment}(POOL_A);

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1);
        gateway.send(REMOTE_CENT_ID + 1, message2);

        _mockAdapters(REMOTE_CENT_ID, message1, MESSAGE_GAS_LIMIT, address(POOL_REFUND));
        _mockAdapters(REMOTE_CENT_ID + 1, message2, MESSAGE_GAS_LIMIT, address(POOL_REFUND));

        vm.expectEmit();
        emit IGateway.SendBatch(REMOTE_CENT_ID, batchId1, message1, batchAdapter, ADAPTER_DATA_1, address(POOL_REFUND));
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID, batchId1, batchHash1, proofAdapter1, ADAPTER_DATA_2);
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID, batchId1, batchHash1, proofAdapter2, ADAPTER_DATA_3);
        vm.expectEmit();
        emit IGateway.SendBatch(
            REMOTE_CENT_ID + 1, batchId2, message2, batchAdapter, ADAPTER_DATA_1, address(POOL_REFUND)
        );
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID + 1, batchId2, batchHash2, proofAdapter1, ADAPTER_DATA_2);
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID + 1, batchId2, batchHash2, proofAdapter2, ADAPTER_DATA_3);
        gateway.endBatching();

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), 0);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), new bytes(0));
        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID + 1, POOL_A), 0);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID + 1, POOL_A), new bytes(0));
        assertEq(gateway.batchLocatorsLength(), 0);
        assertEq(gateway.isBatching(), false);
    }

    function testSendTwoMessageBatchingSameChainDifferentPool() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory message1 = MessageKind.WithPool0.asBytes();
        bytes memory message2 = MessageKind.WithPoolA1.asBytes();
        bytes32 batchHash1 = keccak256(message1);
        bytes32 batchHash2 = keccak256(message2);
        bytes32 batchId1 = keccak256(abi.encodePacked(LOCAL_CENT_ID, REMOTE_CENT_ID, batchHash1));
        bytes32 batchId2 = keccak256(abi.encodePacked(LOCAL_CENT_ID, REMOTE_CENT_ID, batchHash2));

        uint256 payment = MESSAGE_GAS_LIMIT * 3 + ADAPTER_ESTIMATE_1 + ADAPTER_ESTIMATE_2 + ADAPTER_ESTIMATE_3;
        gateway.setRefundAddress(POOL_A, POOL_REFUND);
        gateway.setRefundAddress(POOL_0, POOL_REFUND);
        gateway.subsidizePool{value: payment}(POOL_A);
        gateway.subsidizePool{value: payment}(POOL_0);

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1);
        gateway.send(REMOTE_CENT_ID, message2);

        _mockAdapters(REMOTE_CENT_ID, message1, MESSAGE_GAS_LIMIT, address(POOL_REFUND));
        _mockAdapters(REMOTE_CENT_ID, message2, MESSAGE_GAS_LIMIT, address(POOL_REFUND));

        vm.expectEmit();
        emit IGateway.SendBatch(REMOTE_CENT_ID, batchId1, message1, batchAdapter, ADAPTER_DATA_1, address(POOL_REFUND));
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID, batchId1, batchHash1, proofAdapter1, ADAPTER_DATA_2);
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID, batchId1, batchHash1, proofAdapter2, ADAPTER_DATA_3);
        vm.expectEmit();
        emit IGateway.SendBatch(REMOTE_CENT_ID, batchId2, message2, batchAdapter, ADAPTER_DATA_1, address(POOL_REFUND));
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID, batchId2, batchHash2, proofAdapter1, ADAPTER_DATA_2);
        vm.expectEmit();
        emit IGateway.SendProof(REMOTE_CENT_ID, batchId2, batchHash2, proofAdapter2, ADAPTER_DATA_3);
        gateway.endBatching();

        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_A), 0);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_A), new bytes(0));
        assertEq(gateway.batchGasLimit(REMOTE_CENT_ID, POOL_0), 0);
        assertEq(gateway.outboundBatch(REMOTE_CENT_ID, POOL_0), new bytes(0));
        assertEq(gateway.batchLocatorsLength(), 0);
        assertEq(gateway.isBatching(), false);
    }

    function testSendTwoMessageBatchingUsingTransactionPayment() public {
        gateway.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory message1 = MessageKind.WithPoolA1.asBytes();
        bytes memory message2 = MessageKind.WithPoolA2.asBytes();
        bytes memory batch = bytes.concat(message1, message2);

        gateway.startBatching();
        gateway.send(REMOTE_CENT_ID, message1);
        gateway.send(REMOTE_CENT_ID, message2);

        uint256 payment =
            MESSAGE_GAS_LIMIT * 2 * 3 + ADAPTER_ESTIMATE_1 + ADAPTER_ESTIMATE_2 + ADAPTER_ESTIMATE_3 + 1234;
        gateway.payTransaction{value: payment}(TRANSIENT_REFUND);

        _mockAdapters(REMOTE_CENT_ID, batch, MESSAGE_GAS_LIMIT * 2, TRANSIENT_REFUND);

        gateway.endBatching();

        assertEq(TRANSIENT_REFUND.balance, 1234);
        assertEq(gateway.fuel(), 0);
        assertEq(gateway.transactionRefund(), address(0));
    }
}
