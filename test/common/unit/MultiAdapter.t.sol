// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/Auth.sol";
import {BytesLib} from "../../../src/misc/libraries/BytesLib.sol";

import {MultiAdapter} from "../../../src/common/MultiAdapter.sol";
import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
import {MessageProofLib} from "../../../src/common/libraries/MessageProofLib.sol";
import {IMessageHandler} from "../../../src/common/interfaces/IMessageHandler.sol";
import {IMultiAdapter, MAX_ADAPTER_COUNT} from "../../../src/common/interfaces/IMultiAdapter.sol";

import "forge-std/Test.sol";

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

// -----------------------------------------
//     CONTRACT EXTENSION
// -----------------------------------------

contract MultiAdapterExt is MultiAdapter {
    constructor(uint16 localCentrifugeId_, IMessageHandler gateway_, address deployer)
        MultiAdapter(localCentrifugeId_, gateway, deployer)
    {}

    function adapterDetails(uint16 centrifugeId, IAdapter adapter) public view returns (IMultiAdapter.Adapter memory) {
        return _adapterDetails[centrifugeId][adapter];
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

    bytes constant MESSAGE_1 = "Message 1";
    bytes constant MESSAGE_2 = "Message 2";

    IAdapter payloadAdapter = IAdapter(makeAddr("PayloadAdapter"));
    IAdapter proofAdapter1 = IAdapter(makeAddr("ProofAdapter1"));
    IAdapter proofAdapter2 = IAdapter(makeAddr("ProofAdapter2"));
    IAdapter[] oneAdapter;
    IAdapter[] threeAdapters;

    MockGateway gateway = new MockGateway();
    MultiAdapterExt multiAdapter = new MultiAdapterExt(LOCAL_CENT_ID, gateway, address(this));

    address immutable ANY = makeAddr("ANY");
    address immutable REFUND = makeAddr("REFUND");

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
        multiAdapter.file("gateway", address(gateway));
    }

    function testConstructor() public view {
        assertEq(multiAdapter.localCentrifugeId(), LOCAL_CENT_ID);
        assertEq(address(multiAdapter.gateway()), address(gateway));
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

    function testMultiAdapterFile() public {
        vm.expectEmit();
        emit IMultiAdapter.File("gateway", address(23));
        multiAdapter.file("gateway", address(23));
        assertEq(address(multiAdapter.gateway()), address(23));
    }
}

contract MultiAdapterTestFileAdapters is MultiAdapterTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        multiAdapter.file("unknown", REMOTE_CENT_ID, new IAdapter[](0));
    }

    function testErrFileUnrecognizedParam() public {
        vm.expectRevert(IMultiAdapter.FileUnrecognizedParam.selector);
        multiAdapter.file("unknown", REMOTE_CENT_ID, new IAdapter[](0));
    }

    function testErrEmptyAdapterFile() public {
        vm.expectRevert(IMultiAdapter.EmptyAdapterSet.selector);
        multiAdapter.file("adapters", REMOTE_CENT_ID, new IAdapter[](0));
    }

    function testErrExceedsMax() public {
        IAdapter[] memory tooMuchAdapters = new IAdapter[](MAX_ADAPTER_COUNT + 1);
        vm.expectRevert(IMultiAdapter.ExceedsMax.selector);
        multiAdapter.file("adapters", REMOTE_CENT_ID, tooMuchAdapters);
    }

    function testErrNoDuplicatedAllowed() public {
        IAdapter[] memory duplicatedAdapters = new IAdapter[](2);
        duplicatedAdapters[0] = IAdapter(address(10));
        duplicatedAdapters[1] = IAdapter(address(10));

        vm.expectRevert(IMultiAdapter.NoDuplicatesAllowed.selector);
        multiAdapter.file("adapters", REMOTE_CENT_ID, duplicatedAdapters);
    }

    function testMultiAdapterFileAdapters() public {
        vm.expectEmit();
        emit IMultiAdapter.File("adapters", REMOTE_CENT_ID, threeAdapters);
        multiAdapter.file("adapters", REMOTE_CENT_ID, threeAdapters);

        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID), 0);
        assertEq(multiAdapter.quorum(REMOTE_CENT_ID), threeAdapters.length);

        for (uint256 i; i < threeAdapters.length; i++) {
            IMultiAdapter.Adapter memory adapter = multiAdapter.adapterDetails(REMOTE_CENT_ID, threeAdapters[i]);

            assertEq(adapter.id, i + 1);
            assertEq(adapter.quorum, threeAdapters.length);
            assertEq(adapter.activeSessionId, 0);
            assertEq(address(multiAdapter.adapters(REMOTE_CENT_ID, i)), address(threeAdapters[i]));
        }
    }

    function testMultiAdapterFileAdaptersAdvanceSession() public {
        multiAdapter.file("adapters", REMOTE_CENT_ID, threeAdapters);
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID), 0);

        // Using another chain uses a different active session counter
        multiAdapter.file("adapters", LOCAL_CENT_ID, threeAdapters);
        assertEq(multiAdapter.activeSessionId(LOCAL_CENT_ID), 0);

        multiAdapter.file("adapters", REMOTE_CENT_ID, threeAdapters);
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID), 1);
    }
}

contract MultiAdapterTestHandle is MultiAdapterTest {
    using MessageProofLib for *;

    function testErrInvalidAdapter() public {
        vm.expectRevert(IMultiAdapter.InvalidAdapter.selector);
        multiAdapter.handle(REMOTE_CENT_ID, new bytes(0));
    }

    function testErrEmptyMessage() public {
        multiAdapter.file("adapters", REMOTE_CENT_ID, oneAdapter);

        vm.prank(address(payloadAdapter));
        vm.expectRevert(BytesLib.SliceOutOfBounds.selector);
        multiAdapter.handle(REMOTE_CENT_ID, new bytes(0));
    }

    function testErrNonProofAdapter() public {
        multiAdapter.file("adapters", REMOTE_CENT_ID, threeAdapters);

        vm.prank(address(payloadAdapter));
        vm.expectRevert(IMultiAdapter.NonProofAdapter.selector);
        multiAdapter.handle(REMOTE_CENT_ID, MessageProofLib.serializeMessageProof(bytes32("1")));
    }

    function testErrNonProofAdapterWithOneAdapter() public {
        multiAdapter.file("adapters", REMOTE_CENT_ID, oneAdapter);

        vm.prank(address(payloadAdapter));
        vm.expectRevert(IMultiAdapter.NonProofAdapter.selector);
        multiAdapter.handle(REMOTE_CENT_ID, MessageProofLib.serializeMessageProof(bytes32("1")));
    }

    function testErrNonPayloadAdapter() public {
        multiAdapter.file("adapters", REMOTE_CENT_ID, threeAdapters);

        vm.prank(address(proofAdapter1));
        vm.expectRevert(IMultiAdapter.NonPayloadAdapter.selector);
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
    }

    function testMessageWithOneAdapter() public {
        multiAdapter.file("adapters", REMOTE_CENT_ID, oneAdapter);

        bytes32 payloadId = keccak256(abi.encodePacked(REMOTE_CENT_ID, LOCAL_CENT_ID, keccak256(MESSAGE_1)));

        vm.prank(address(payloadAdapter));
        vm.expectEmit();
        emit IMultiAdapter.HandlePayload(REMOTE_CENT_ID, payloadId, MESSAGE_1, payloadAdapter);
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);

        assertEq(gateway.handled(REMOTE_CENT_ID, 0), MESSAGE_1);
    }

    function testMessageAndProofs() public {
        multiAdapter.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory message = MESSAGE_1;
        bytes memory proof = keccak256(MESSAGE_1).serializeMessageProof();
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
        multiAdapter.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory message = MESSAGE_1;
        bytes memory proof = keccak256(MESSAGE_1).serializeMessageProof();

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
        multiAdapter.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory message = MESSAGE_1;
        bytes memory proof = keccak256(MESSAGE_1).serializeMessageProof();

        vm.prank(address(payloadAdapter));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        vm.prank(address(proofAdapter1));
        multiAdapter.handle(REMOTE_CENT_ID, proof);
        vm.prank(address(proofAdapter2));
        multiAdapter.handle(REMOTE_CENT_ID, proof);

        bytes memory batch2 = MESSAGE_2;
        bytes memory proof2 = keccak256(MESSAGE_2).serializeMessageProof();

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
        multiAdapter.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory message = MESSAGE_1;
        bytes memory proof = keccak256(MESSAGE_1).serializeMessageProof();

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
        multiAdapter.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory message = MESSAGE_1;
        bytes memory proof = keccak256(MESSAGE_1).serializeMessageProof();

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
        multiAdapter.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory message = MESSAGE_1;
        bytes memory proof = keccak256(MESSAGE_1).serializeMessageProof();

        vm.prank(address(payloadAdapter));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        vm.prank(address(proofAdapter1));
        multiAdapter.handle(REMOTE_CENT_ID, proof);

        multiAdapter.file("adapters", REMOTE_CENT_ID, threeAdapters);

        vm.prank(address(proofAdapter2));
        multiAdapter.handle(REMOTE_CENT_ID, proof);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(message, 0, 0, 1);
    }
}

contract MultiAdapterTestInitiateRecovery is MultiAdapterTest {
    bytes32 constant PAYLOAD_HASH = bytes32("1");

    function testErrInvalidAdapter() public {
        vm.expectRevert(IMultiAdapter.InvalidAdapter.selector);
        multiAdapter.initiateRecovery(REMOTE_CENT_ID, payloadAdapter, PAYLOAD_HASH);
    }

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        multiAdapter.initiateRecovery(REMOTE_CENT_ID, payloadAdapter, PAYLOAD_HASH);
    }

    function testInitiateRecovery() public {
        multiAdapter.file("adapters", REMOTE_CENT_ID, oneAdapter);

        vm.expectEmit();
        emit IMultiAdapter.InitiateRecovery(REMOTE_CENT_ID, PAYLOAD_HASH, payloadAdapter);
        multiAdapter.initiateRecovery(REMOTE_CENT_ID, payloadAdapter, PAYLOAD_HASH);

        assertEq(
            multiAdapter.recoveries(REMOTE_CENT_ID, payloadAdapter, PAYLOAD_HASH),
            block.timestamp + multiAdapter.RECOVERY_CHALLENGE_PERIOD()
        );
    }
}

contract MultiAdapterTestDisputeRecovery is MultiAdapterTest {
    bytes32 constant PAYLOAD_HASH = bytes32("1");

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        multiAdapter.initiateRecovery(REMOTE_CENT_ID, payloadAdapter, PAYLOAD_HASH);
    }

    function testErrRecoveryNotInitiated() public {
        vm.expectRevert(IMultiAdapter.RecoveryNotInitiated.selector);
        multiAdapter.disputeRecovery(REMOTE_CENT_ID, payloadAdapter, PAYLOAD_HASH);
    }

    function testDisputeRecovery() public {
        multiAdapter.file("adapters", REMOTE_CENT_ID, oneAdapter);
        multiAdapter.initiateRecovery(REMOTE_CENT_ID, payloadAdapter, PAYLOAD_HASH);

        vm.expectEmit();
        emit IMultiAdapter.DisputeRecovery(REMOTE_CENT_ID, PAYLOAD_HASH, payloadAdapter);
        multiAdapter.disputeRecovery(REMOTE_CENT_ID, payloadAdapter, PAYLOAD_HASH);

        assertEq(multiAdapter.recoveries(REMOTE_CENT_ID, payloadAdapter, PAYLOAD_HASH), 0);
    }
}

contract MultiAdapterTestExecuteRecovery is MultiAdapterTest {
    function testErrRecoveryNotInitiated() public {
        vm.expectRevert(IMultiAdapter.RecoveryNotInitiated.selector);
        multiAdapter.executeRecovery(REMOTE_CENT_ID, payloadAdapter, bytes(""));
    }

    function testErrRecoveryChallengePeriodNotEnded() public {
        multiAdapter.file("adapters", REMOTE_CENT_ID, oneAdapter);

        multiAdapter.initiateRecovery(REMOTE_CENT_ID, payloadAdapter, keccak256(MESSAGE_1));

        vm.prank(ANY);
        vm.expectRevert(IMultiAdapter.RecoveryChallengePeriodNotEnded.selector);
        multiAdapter.executeRecovery(REMOTE_CENT_ID, payloadAdapter, MESSAGE_1);
    }

    function testExecuteRecovery() public {
        multiAdapter.file("adapters", REMOTE_CENT_ID, oneAdapter);

        multiAdapter.initiateRecovery(REMOTE_CENT_ID, payloadAdapter, keccak256(MESSAGE_1));

        vm.warp(multiAdapter.RECOVERY_CHALLENGE_PERIOD() + 1);

        vm.prank(ANY);
        emit IMultiAdapter.ExecuteRecovery(REMOTE_CENT_ID, MESSAGE_1, payloadAdapter);
        multiAdapter.executeRecovery(REMOTE_CENT_ID, payloadAdapter, MESSAGE_1);

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
        multiAdapter.file("adapters", REMOTE_CENT_ID, threeAdapters);

        bytes memory message = MESSAGE_1;
        bytes memory proof = keccak256(MESSAGE_1).serializeMessageProof();
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
