// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {Gateway, IRoot, IGasService, IGateway, MessageProofLib} from "src/common/Gateway.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {PoolId} from "src/common/types/PoolId.sol";

import {BytesLib} from "src/misc/libraries/BytesLib.sol";

import {IMessageProperties} from "src/common/interfaces/IMessageProperties.sol";
import {IMessageProcessor} from "src/common/interfaces/IMessageProcessor.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";

// -----------------------------------------
//     MESSAGE MOCKING
// -----------------------------------------

PoolId constant POOL_A = PoolId.wrap(23);
PoolId constant POOL_0 = PoolId.wrap(0);

enum MessageKind {
    Recovery,
    WithPool0,
    WithPoolA10,
    WithPoolA100
}

function length(MessageKind kind) pure returns (uint16) {
    if (kind == MessageKind.WithPoolA10) return 11;
    if (kind == MessageKind.WithPoolA100) return 101;
    return 1;
}

function asBytes(MessageKind kind) pure returns (bytes memory) {
    bytes memory encoded = new bytes(length(kind));
    encoded[0] = bytes1(uint8(kind) + 2); // Start as index 2
    return encoded;
}

using {asBytes, length} for MessageKind;

// A MessageLib agnostic processor
contract MockProcessor is IMessageProperties, IMessageHandler {
    using BytesLib for bytes;

    function handle(uint16 remoteCentrifugeId, bytes calldata message) external {}

    function isMessageRecovery(bytes calldata message) external pure returns (bool) {
        return message.toUint8(0) == uint8(MessageKind.Recovery);
    }

    function messageLength(bytes calldata message) external pure returns (uint16) {
        return MessageKind(message.toUint8(0)).length();
    }

    function messagePoolId(bytes calldata message) external pure returns (PoolId) {
        if (message.toUint8(0) == uint8(MessageKind.WithPoolA10)) return POOL_0;
        if (message.toUint8(0) == uint8(MessageKind.WithPoolA100)) return POOL_A;
        if (message.toUint8(0) == uint8(MessageKind.WithPoolA100)) return POOL_A;
        revert("Unreachable: message never asked for pool");
    }
}

// -----------------------------------------
//     GATEWAY EXTENSION
// -----------------------------------------

contract GatewayExt is Gateway {
    constructor(uint16 localCentrifugeId_, IRoot root_, IGasService gasService_)
        Gateway(localCentrifugeId_, root_, gasService_)
    {}

    function activeAdapters(uint16 centrifugeId, IAdapter adapter) public view returns (IGateway.Adapter memory) {
        return _activeAdapters[centrifugeId][adapter];
    }
}

// -----------------------------------------
//     GATEWAY TESTS
// -----------------------------------------

contract GatewayTest is Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = 23;
    uint16 constant REMOTE_CENTRIFUGE_ID = 24;

    uint256 constant FIRST_ADAPTER_ESTIMATE = 1.5 gwei;
    uint256 constant SECOND_ADAPTER_ESTIMATE = 1 gwei;
    uint256 constant THIRD_ADAPTER_ESTIMATE = 0.5 gwei;
    uint256 constant MESSAGE_GAS_LIMIT = 10.0 gwei;
    uint256 constant MAX_BATCH_SIZE = 100.0 gwei;

    IGasService gasService = IGasService(makeAddr("GasService"));
    IRoot root = IRoot(makeAddr("Root"));
    IAdapter batchAdapter = IAdapter(makeAddr("BatchAdapter"));
    IAdapter proofAdapter1 = IAdapter(makeAddr("ProofAdapter1"));
    IAdapter proofAdapter2 = IAdapter(makeAddr("ProofAdapter2"));
    IAdapter[] adapters;

    MockProcessor processor = new MockProcessor();
    GatewayExt gateway = new GatewayExt(LOCAL_CENTRIFUGE_ID, IRoot(address(root)), IGasService(address(gasService)));

    function _mockPause(bool isPaused) internal {
        vm.mockCall(address(root), abi.encodeWithSelector(IRoot.paused.selector), abi.encode(isPaused));
    }

    function setUp() public {
        adapters.push(batchAdapter);
        adapters.push(proofAdapter1);
        adapters.push(proofAdapter2);
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, adapters);
        gateway.file("processor", address(processor));

        vm.mockCall(
            address(gasService), abi.encodeWithSelector(IGasService.gasLimit.selector), abi.encode(MESSAGE_GAS_LIMIT)
        );
        vm.mockCall(
            address(gasService), abi.encodeWithSelector(IGasService.maxBatchSize.selector), abi.encode(MAX_BATCH_SIZE)
        );
        _mockPause(false);
    }

    function testConstructor() public view {
        assertEq(gateway.localCentrifugeId(), LOCAL_CENTRIFUGE_ID);
        assertEq(address(gateway.root()), address(root));
        assertEq(address(gateway.gasService()), address(gasService));

        (, address refund) = gateway.subsidy(POOL_0);
        assertEq(refund, address(gateway));

        assertEq(gateway.wards(address(this)), 1);
    }

    function testMessageProofLib(bytes32 hash_) public pure {
        assertEq(hash_, MessageProofLib.deserializeMessageProof(MessageProofLib.serializeMessageProof(hash_)));
    }
}

contract GatewayFileTest is GatewayTest {
    function testErrNotAuthorized() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.file("unknown", address(1));
    }

    function testErrFileUnrecognizedParam() public {
        vm.expectRevert(IGateway.FileUnrecognizedParam.selector);
        gateway.file("unknown", address(1));
    }

    function testGatewayFileSuccess() public {
        vm.expectEmit();
        emit IGateway.File("processor", address(23));
        gateway.file("processor", address(23));
        assertEq(address(gateway.processor()), address(23));

        gateway.file("gasService", address(42));
        assertEq(address(gateway.gasService()), address(42));
    }
}

contract GatewayFileAdaptersTest is GatewayTest {
    function testErrNotAuthorized() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.file("unknown", REMOTE_CENTRIFUGE_ID, new IAdapter[](0));
    }

    function testErrFileUnrecognizedParam() public {
        vm.expectRevert(IGateway.FileUnrecognizedParam.selector);
        gateway.file("unknown", REMOTE_CENTRIFUGE_ID, new IAdapter[](0));
    }

    function testErrEmptyAdapterFile() public {
        vm.expectRevert(IGateway.EmptyAdapterSet.selector);
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, new IAdapter[](0));
    }

    function testErrExceedsMax() public {
        IAdapter[] memory adapters = new IAdapter[](gateway.MAX_ADAPTER_COUNT() + 1);
        vm.expectRevert(IGateway.ExceedsMax.selector);
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, adapters);
    }

    function testErrNoDuplicatedAllowed() public {
        IAdapter[] memory adapters = new IAdapter[](2);
        adapters[0] = IAdapter(address(10));
        adapters[1] = IAdapter(address(10));

        vm.expectRevert(IGateway.NoDuplicatesAllowed.selector);
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, adapters);
    }

    function testGatewayFileAdaptersSuccess() public {
        vm.expectEmit();
        emit IGateway.File("adapters", REMOTE_CENTRIFUGE_ID, adapters);
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, adapters);

        assertEq(gateway.activeSessionId(REMOTE_CENTRIFUGE_ID), 1);
        assertEq(gateway.quorum(REMOTE_CENTRIFUGE_ID), adapters.length);

        for (uint256 i; i < adapters.length; i++) {
            IGateway.Adapter memory adapter = gateway.activeAdapters(REMOTE_CENTRIFUGE_ID, adapters[i]);

            assertEq(adapter.id, i + 1);
            assertEq(adapter.quorum, adapters.length);
            assertEq(adapter.activeSessionId, 1);
            assertEq(address(gateway.adapters(REMOTE_CENTRIFUGE_ID, i)), address(adapters[i]));
        }
    }

    function testGatewayFileAdaptersAdvanceSession() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, adapters);
        assertEq(gateway.activeSessionId(REMOTE_CENTRIFUGE_ID), 1);

        // Using another chain uses a different active session counter
        gateway.file("adapters", LOCAL_CENTRIFUGE_ID, adapters);
        assertEq(gateway.activeSessionId(LOCAL_CENTRIFUGE_ID), 0);

        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, adapters);
        assertEq(gateway.activeSessionId(REMOTE_CENTRIFUGE_ID), 2);
    }
}

contract GatewayReceiveTest is GatewayTest {
    function testGatewayReceiveSuccess() public {
        (bool success,) = address(gateway).call{value: 100}(new bytes(0));

        assertEq(success, true);

        (uint96 value,) = gateway.subsidy(POOL_0);
        assertEq(value, 100);

        assertEq(address(gateway).balance, 100);
    }
}

contract GatewayHandleTest is GatewayTest {
    function testErrPaused() public {
        _mockPause(true);
        vm.expectRevert(IGateway.Paused.selector);
        gateway.handle(REMOTE_CENTRIFUGE_ID, new bytes(0));
    }

    function testErrInvalidAdapter() public {
        vm.expectRevert(IGateway.InvalidAdapter.selector);
        gateway.handle(REMOTE_CENTRIFUGE_ID, new bytes(0));
    }

    function testErrNonProofAdapter() public {
        vm.prank(address(batchAdapter));
        vm.expectRevert(IGateway.NonProofAdapter.selector);
        gateway.handle(REMOTE_CENTRIFUGE_ID, MessageProofLib.serializeMessageProof(bytes32("1")));
    }

    function testErrNonBatchAdapter() public {
        vm.prank(address(proofAdapter1));
        vm.expectRevert(IGateway.NonBatchAdapter.selector);
        gateway.handle(REMOTE_CENTRIFUGE_ID, MessageKind.WithPool0.asBytes());
    }

    function testErrEmptyMessage() public {
        vm.prank(address(batchAdapter));
        vm.expectRevert("toUint8_outOfBounds");
        gateway.handle(REMOTE_CENTRIFUGE_ID, new bytes(0));
    }
}
