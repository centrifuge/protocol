// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/Auth.sol";
import {BytesLib} from "../../../src/misc/libraries/BytesLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {MultiAdapter} from "../../../src/common/MultiAdapter.sol";
import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
import {MessageProofLib} from "../../../src/common/libraries/MessageProofLib.sol";
import {IMessageHandler} from "../../../src/common/interfaces/IMessageHandler.sol";
import {IMessageProperties} from "../../../src/common/interfaces/IMessageProperties.sol";
import {IMultiAdapter, MAX_ADAPTER_COUNT} from "../../../src/common/interfaces/IMultiAdapter.sol";

import "forge-std/Test.sol";

PoolId constant POOL_A = PoolId.wrap(23);
PoolId constant POOL_0 = PoolId.wrap(0);

// -----------------------------------------
//     MOCKING
// -----------------------------------------

contract MockGateway is IMessageHandler {
    using BytesLib for bytes;

    mapping(uint16 => bytes[]) public handled;

    function handle(uint16 centrifugeId, bytes memory payload) external {
        handled[centrifugeId].push(payload);
    }

    function count(uint16 centrifugeId) external view returns (uint256) {
        return handled[centrifugeId].length;
    }
}

contract MockMessageProperties is IMessageProperties {
    function messageLength(bytes calldata message) external pure returns (uint16) {}
    function messagePoolIdPayment(bytes calldata message) external pure returns (PoolId) {}

    function messagePoolId(bytes calldata message) external pure returns (PoolId) {
        if (message.length >= 6) {
            bytes memory prefix = message[0:6];
            if (keccak256(prefix) == keccak256("POOL_A")) return POOL_A;
            revert("Unreachable: message with pool but not POOL_A");
        }
        return PoolId.wrap(0);
    }
}

// -----------------------------------------
//     CONTRACT EXTENSION
// -----------------------------------------

contract MultiAdapterExt is MultiAdapter {
    constructor(
        uint16 localCentrifugeId_,
        IMessageHandler gateway_,
        IMessageProperties messageProperties_,
        address deployer
    ) MultiAdapter(localCentrifugeId_, gateway_, messageProperties_, deployer) {}

    function adapterDetails(uint16 centrifugeId, PoolId poolId, IAdapter adapter)
        public
        view
        returns (IMultiAdapter.Adapter memory)
    {
        return _adapterDetails[centrifugeId][poolId][adapter];
    }
}

// -----------------------------------------
//     TESTS
// -----------------------------------------

contract MultiAdapterTest is Test {
    uint16 constant LOCAL_CENT_ID = 23;
    uint16 constant REMOTE_CENT_ID = 24;

    uint256 constant ADAPTER_ESTIMATE_1 = 1.5 gwei;
    uint256 constant ADAPTER_ESTIMATE_2 = 1 gwei;
    uint256 constant ADAPTER_ESTIMATE_3 = 0.5 gwei;

    bytes32 constant ADAPTER_DATA_1 = bytes32("data1");
    bytes32 constant ADAPTER_DATA_2 = bytes32("data2");
    bytes32 constant ADAPTER_DATA_3 = bytes32("data3");

    uint256 constant GAS_LIMIT = 10.0 gwei;

    bytes constant MESSAGE_1 = "POOL_A: Message 1";
    bytes constant MESSAGE_2 = "POOL_A: Message 2";
    bytes constant PROOF_1 = "1POOL_A";
    bytes constant MESSAGE_POOL_0 = "Message";

    IAdapter payloadAdapter = IAdapter(makeAddr("PayloadAdapter"));
    IAdapter proofAdapter1 = IAdapter(makeAddr("ProofAdapter1"));
    IAdapter proofAdapter2 = IAdapter(makeAddr("ProofAdapter2"));
    IAdapter[] oneAdapter;
    IAdapter[] threeAdapters;

    MockGateway gateway = new MockGateway();
    MockMessageProperties messageProperties = new MockMessageProperties();
    MultiAdapterExt multiAdapter = new MultiAdapterExt(LOCAL_CENT_ID, gateway, messageProperties, address(this));

    address immutable ANY = makeAddr("ANY");
    address immutable REFUND = makeAddr("REFUND");
    address immutable RECOVERER = makeAddr("RECOVERER");

    function _mockAdapter(IAdapter adapter, bytes memory message, uint256 estimate, bytes32 adapterData) internal {
        vm.mockCall(
            address(adapter),
            abi.encodeWithSelector(IAdapter.estimate.selector, REMOTE_CENT_ID, message, GAS_LIMIT),
            abi.encode(GAS_LIMIT + estimate)
        );

        vm.mockCall(
            address(adapter),
            GAS_LIMIT + estimate,
            abi.encodeWithSelector(IAdapter.send.selector, REMOTE_CENT_ID, message, GAS_LIMIT, REFUND),
            abi.encode(adapterData)
        );
    }

    function assertVotes(bytes memory message, uint16 r1, uint16 r2, uint16 r3) internal view {
        uint16[8] memory votes = multiAdapter.votes(REMOTE_CENT_ID, keccak256(message));
        assertEq(votes[0], r1);
        assertEq(votes[1], r2);
        assertEq(votes[2], r3);
    }

    function setUp() public {
        oneAdapter.push(payloadAdapter);
        threeAdapters.push(payloadAdapter);
        threeAdapters.push(proofAdapter1);
        threeAdapters.push(proofAdapter2);
    }

    function testConstructor() public view {
        assertEq(multiAdapter.localCentrifugeId(), LOCAL_CENT_ID);
        assertEq(address(multiAdapter.gateway()), address(gateway));
        assertEq(address(multiAdapter.messageProperties()), address(messageProperties));
    }
}

contract MultiAdapterTestFile is MultiAdapterTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        multiAdapter.file("unknown", address(1));
    }

    function testErrFileUnrecognizedParam() public {
        vm.expectRevert(IMultiAdapter.FileUnrecognizedParam.selector);
        multiAdapter.file("unknown", address(1));
    }

    function testMultiAdapterFileGateway() public {
        vm.expectEmit();
        emit IMultiAdapter.File("gateway", address(23));
        multiAdapter.file("gateway", address(23));
        assertEq(address(multiAdapter.gateway()), address(23));
    }

    function testMultiAdapterFileMessageProperties() public {
        vm.expectEmit();
        emit IMultiAdapter.File("messageProperties", address(23));
        multiAdapter.file("messageProperties", address(23));
        assertEq(address(multiAdapter.messageProperties()), address(23));
    }
}

contract MultiAdapterTestFileAdapters is MultiAdapterTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, new IAdapter[](0));
    }

    function testErrEmptyAdapterFile() public {
        vm.expectRevert(IMultiAdapter.EmptyAdapterSet.selector);
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, new IAdapter[](0));
    }

    function testErrExceedsMax() public {
        IAdapter[] memory tooMuchAdapters = new IAdapter[](MAX_ADAPTER_COUNT + 1);
        vm.expectRevert(IMultiAdapter.ExceedsMax.selector);
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, tooMuchAdapters);
    }

    function testErrNoDuplicatedAllowed() public {
        IAdapter[] memory duplicatedAdapters = new IAdapter[](2);
        duplicatedAdapters[0] = IAdapter(address(10));
        duplicatedAdapters[1] = IAdapter(address(10));

        vm.expectRevert(IMultiAdapter.NoDuplicatesAllowed.selector);
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, duplicatedAdapters);
    }

    function testMultiAdapterFileAdapters() public {
        vm.expectEmit();
        emit IMultiAdapter.SetAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters);
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters);

        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_A), 0);
        assertEq(multiAdapter.quorum(REMOTE_CENT_ID, POOL_A), threeAdapters.length);

        for (uint256 i; i < threeAdapters.length; i++) {
            IMultiAdapter.Adapter memory adapter = multiAdapter.adapterDetails(REMOTE_CENT_ID, POOL_A, threeAdapters[i]);

            assertEq(adapter.id, i + 1);
            assertEq(adapter.quorum, threeAdapters.length);
            assertEq(adapter.activeSessionId, 0);
            assertEq(address(multiAdapter.adapters(REMOTE_CENT_ID, POOL_A, i)), address(threeAdapters[i]));
        }
    }

    function testMultiAdapterFileAdaptersAdvanceSession() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters);
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_A), 0);

        // Using another chain uses a different active session counter
        multiAdapter.setAdapters(LOCAL_CENT_ID, POOL_A, threeAdapters);
        assertEq(multiAdapter.activeSessionId(LOCAL_CENT_ID, POOL_A), 0);

        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters);
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_A), 1);
    }
}

contract MultiAdapterTestSetRecoveryAddress is MultiAdapterTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        multiAdapter.setRecoveryAddress(POOL_A, RECOVERER);
    }

    function testSetRecoveryAddress() public {
        vm.expectEmit();
        emit IMultiAdapter.SetRecoveryAddress(POOL_A, RECOVERER);
        multiAdapter.setRecoveryAddress(POOL_A, RECOVERER);
    }
}

contract MultiAdapterTestHandle is MultiAdapterTest {
    using MessageProofLib for *;

    function testErrInvalidAdapter() public {
        vm.expectRevert(IMultiAdapter.InvalidAdapter.selector);
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
    }

    function testErrEmptyMessage() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_0, oneAdapter);

        vm.prank(address(payloadAdapter));
        vm.expectRevert(BytesLib.SliceOutOfBounds.selector);
        multiAdapter.handle(REMOTE_CENT_ID, new bytes(0));
    }

    function testErrNonProofAdapter() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters);

        vm.prank(address(payloadAdapter));
        vm.expectRevert(IMultiAdapter.NonProofAdapter.selector);
        multiAdapter.handle(REMOTE_CENT_ID, MessageProofLib.createMessageProof(POOL_A, keccak256(MESSAGE_1)));
    }

    function testErrNonProofAdapterWithOneAdapter() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, oneAdapter);

        vm.prank(address(payloadAdapter));
        vm.expectRevert(IMultiAdapter.NonProofAdapter.selector);
        multiAdapter.handle(REMOTE_CENT_ID, MessageProofLib.createMessageProof(POOL_A, keccak256(MESSAGE_1)));
    }

    function testErrNonPayloadAdapter() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters);

        vm.prank(address(proofAdapter1));
        vm.expectRevert(IMultiAdapter.NonPayloadAdapter.selector);
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
    }

    function testMessageWithOneAdapter() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, oneAdapter);

        bytes32 payloadId = keccak256(abi.encodePacked(REMOTE_CENT_ID, LOCAL_CENT_ID, keccak256(MESSAGE_1)));

        vm.prank(address(payloadAdapter));
        vm.expectEmit();
        emit IMultiAdapter.HandlePayload(REMOTE_CENT_ID, payloadId, MESSAGE_1, payloadAdapter);
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);

        assertEq(gateway.handled(REMOTE_CENT_ID, 0), MESSAGE_1);
    }

    function testMessageAndProofs() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters);

        bytes memory message = MESSAGE_1;
        bytes memory proof = MessageProofLib.createMessageProof(POOL_A, keccak256(MESSAGE_1));
        bytes32 payloadId = keccak256(abi.encodePacked(REMOTE_CENT_ID, LOCAL_CENT_ID, keccak256(message)));

        vm.prank(address(payloadAdapter));
        vm.expectEmit();
        emit IMultiAdapter.HandlePayload(REMOTE_CENT_ID, payloadId, message, payloadAdapter);
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(message, 1, 0, 0);

        vm.prank(address(proofAdapter1));
        vm.expectEmit();
        emit IMultiAdapter.HandleProof(REMOTE_CENT_ID, payloadId, keccak256(message), proofAdapter1);
        multiAdapter.handle(REMOTE_CENT_ID, proof);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(message, 1, 1, 0);

        vm.prank(address(proofAdapter2));
        vm.expectEmit();
        emit IMultiAdapter.HandleProof(REMOTE_CENT_ID, payloadId, keccak256(message), proofAdapter2);
        multiAdapter.handle(REMOTE_CENT_ID, proof);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertEq(gateway.handled(REMOTE_CENT_ID, 0), message);
        assertVotes(message, 0, 0, 0);
    }

    function testSameMessageAndProofs() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters);

        bytes memory message = MESSAGE_1;
        bytes memory proof = MessageProofLib.createMessageProof(POOL_A, keccak256(MESSAGE_1));

        vm.prank(address(payloadAdapter));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        vm.prank(address(proofAdapter1));
        multiAdapter.handle(REMOTE_CENT_ID, proof);
        vm.prank(address(proofAdapter2));
        multiAdapter.handle(REMOTE_CENT_ID, proof);

        vm.prank(address(payloadAdapter));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(message, 1, 0, 0);

        vm.prank(address(proofAdapter1));
        multiAdapter.handle(REMOTE_CENT_ID, proof);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(message, 1, 1, 0);

        vm.prank(address(proofAdapter2));
        multiAdapter.handle(REMOTE_CENT_ID, proof);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertEq(gateway.handled(REMOTE_CENT_ID, 1), message);
        assertVotes(message, 0, 0, 0);
    }

    function testOtherMessageAndProofs() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters);

        bytes memory message = MESSAGE_1;
        bytes memory proof = MessageProofLib.createMessageProof(POOL_A, keccak256(MESSAGE_1));

        vm.prank(address(payloadAdapter));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        vm.prank(address(proofAdapter1));
        multiAdapter.handle(REMOTE_CENT_ID, proof);
        vm.prank(address(proofAdapter2));
        multiAdapter.handle(REMOTE_CENT_ID, proof);

        bytes memory batch2 = MESSAGE_2;
        bytes memory proof2 = MessageProofLib.createMessageProof(POOL_A, keccak256(MESSAGE_2));

        vm.prank(address(payloadAdapter));
        multiAdapter.handle(REMOTE_CENT_ID, batch2);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(batch2, 1, 0, 0);

        vm.prank(address(proofAdapter1));
        multiAdapter.handle(REMOTE_CENT_ID, proof2);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(batch2, 1, 1, 0);

        vm.prank(address(proofAdapter2));
        multiAdapter.handle(REMOTE_CENT_ID, proof2);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertEq(gateway.handled(REMOTE_CENT_ID, 1), batch2);
        assertVotes(batch2, 0, 0, 0);
    }

    function testMessageAfterProofs() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters);

        bytes memory message = MESSAGE_1;
        bytes memory proof = MessageProofLib.createMessageProof(POOL_A, keccak256(MESSAGE_1));

        vm.prank(address(proofAdapter1));
        multiAdapter.handle(REMOTE_CENT_ID, proof);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(message, 0, 1, 0);

        vm.prank(address(proofAdapter2));
        multiAdapter.handle(REMOTE_CENT_ID, proof);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(message, 0, 1, 1);

        vm.prank(address(payloadAdapter));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(message, 0, 0, 0);
    }

    function testOneFasterAdapter() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters);

        bytes memory message = MESSAGE_1;
        bytes memory proof = MessageProofLib.createMessageProof(POOL_A, keccak256(MESSAGE_1));

        vm.prank(address(payloadAdapter));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        vm.prank(address(payloadAdapter));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(message, 2, 0, 0);

        vm.prank(address(proofAdapter1));
        multiAdapter.handle(REMOTE_CENT_ID, proof);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(message, 2, 1, 0);

        vm.prank(address(proofAdapter2));
        multiAdapter.handle(REMOTE_CENT_ID, proof);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(message, 1, 0, 0);

        vm.prank(address(proofAdapter1));
        multiAdapter.handle(REMOTE_CENT_ID, proof);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(message, 1, 1, 0);

        vm.prank(address(proofAdapter2));
        multiAdapter.handle(REMOTE_CENT_ID, proof);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertVotes(message, 0, 0, 0);
    }

    function testVotesAfterNewSession() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters);

        bytes memory message = MESSAGE_1;
        bytes memory proof = MessageProofLib.createMessageProof(POOL_A, keccak256(MESSAGE_1));

        vm.prank(address(payloadAdapter));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        vm.prank(address(proofAdapter1));
        multiAdapter.handle(REMOTE_CENT_ID, proof);

        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters);

        vm.prank(address(proofAdapter2));
        multiAdapter.handle(REMOTE_CENT_ID, proof);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(message, 0, 0, 1);
    }
}

contract MultiAdapterTestExecuteRecovery is MultiAdapterTest {
    function testErrRecovererNotAllowed() public {
        vm.prank(ANY);
        vm.expectRevert(IMultiAdapter.RecovererNotAllowed.selector);
        multiAdapter.executeRecovery(REMOTE_CENT_ID, POOL_A, payloadAdapter, bytes(""));
    }

    function testExecuteRecovery() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, oneAdapter);
        multiAdapter.setRecoveryAddress(POOL_A, RECOVERER);

        vm.prank(RECOVERER);
        emit IMultiAdapter.ExecuteRecovery(REMOTE_CENT_ID, MESSAGE_1, payloadAdapter);
        multiAdapter.executeRecovery(REMOTE_CENT_ID, POOL_A, payloadAdapter, MESSAGE_1);

        assertEq(gateway.handled(REMOTE_CENT_ID, 0), MESSAGE_1);
    }

    function testExecuteRecoveryWithProofs() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters);
        multiAdapter.setRecoveryAddress(POOL_A, RECOVERER);

        bytes memory proof = MessageProofLib.createMessageProof(POOL_A, keccak256(MESSAGE_1));

        vm.startPrank(RECOVERER);

        multiAdapter.executeRecovery(REMOTE_CENT_ID, POOL_A, payloadAdapter, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 0); // nothing yet

        multiAdapter.executeRecovery(REMOTE_CENT_ID, POOL_A, proofAdapter1, proof);
        assertEq(gateway.count(REMOTE_CENT_ID), 0); // nothing yet

        multiAdapter.executeRecovery(REMOTE_CENT_ID, POOL_A, proofAdapter2, proof);
        assertEq(gateway.count(REMOTE_CENT_ID), 1); // executed!
        assertEq(gateway.handled(REMOTE_CENT_ID, 0), MESSAGE_1);
    }
}

contract MultiAdapterTestSend is MultiAdapterTest {
    using MessageProofLib for *;

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        multiAdapter.send(REMOTE_CENT_ID, new bytes(0), GAS_LIMIT, REFUND);
    }

    function testErrEmptyAdapterSet() public {
        vm.expectRevert(IMultiAdapter.EmptyAdapterSet.selector);
        multiAdapter.send(REMOTE_CENT_ID, MESSAGE_1, GAS_LIMIT, REFUND);
    }

    function testSendMessage() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters);

        bytes memory message = MESSAGE_1;
        bytes memory proof = MessageProofLib.createMessageProof(POOL_A, keccak256(MESSAGE_1));
        bytes32 batchHash = keccak256(MESSAGE_1);
        bytes32 payloadId = keccak256(abi.encodePacked(LOCAL_CENT_ID, REMOTE_CENT_ID, batchHash));

        uint256 cost = GAS_LIMIT * 3 + ADAPTER_ESTIMATE_1 + ADAPTER_ESTIMATE_2 + ADAPTER_ESTIMATE_3;

        _mockAdapter(payloadAdapter, message, ADAPTER_ESTIMATE_1, ADAPTER_DATA_1);
        _mockAdapter(proofAdapter1, proof, ADAPTER_ESTIMATE_2, ADAPTER_DATA_2);
        _mockAdapter(proofAdapter2, proof, ADAPTER_ESTIMATE_3, ADAPTER_DATA_3);

        vm.expectEmit();
        emit IMultiAdapter.SendPayload(
            REMOTE_CENT_ID, payloadId, message, payloadAdapter, ADAPTER_DATA_1, address(REFUND)
        );
        vm.expectEmit();
        emit IMultiAdapter.SendProof(REMOTE_CENT_ID, payloadId, batchHash, proofAdapter1, ADAPTER_DATA_2);
        vm.expectEmit();
        emit IMultiAdapter.SendProof(REMOTE_CENT_ID, payloadId, batchHash, proofAdapter2, ADAPTER_DATA_3);
        multiAdapter.send{value: cost}(REMOTE_CENT_ID, message, GAS_LIMIT, REFUND);
    }
}
