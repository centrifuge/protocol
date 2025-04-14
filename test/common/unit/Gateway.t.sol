// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "test/common/mocks/Mock.sol";

import {MockERC6909} from "test/misc/mocks/MockERC6909.sol";

import {ERC20} from "src/misc/ERC20.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {Gateway, IRoot, IGasService, IGateway} from "src/common/Gateway.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {PoolId, newPoolId} from "src/common/types/PoolId.sol";

import {MockAdapter} from "test/common/mocks/MockAdapter.sol";
import {MockRoot} from "test/common/mocks/MockRoot.sol";
import {MockGasService} from "test/common/mocks/MockGasService.sol";

import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IMessageProperties} from "src/common/interfaces/IMessageProperties.sol";

contract MockProcessor is Mock, IMessageHandler, IMessageProperties {
    using MessageLib for *;

    mapping(bytes => uint256) public received;

    function handle(uint16, bytes memory message) public {
        values_bytes["handle_message"] = message;
        received[message]++;
    }

    // TODO: simplify tests to avoid using MessageLib. The Gateway should work for any kind of message encoding.

    function isMessageRecovery(bytes calldata message) external pure returns (bool) {
        uint8 code = message.messageCode();
        return code == uint8(MessageType.InitiateMessageRecovery) || code == uint8(MessageType.DisputeMessageRecovery);
    }

    function messageLength(bytes calldata message) external pure returns (uint16) {
        return message.messageLength();
    }

    function messagePoolId(bytes calldata message) external pure returns (PoolId) {
        return message.messagePoolId();
    }

    function messageProofHash(bytes calldata message) external pure returns (bytes32) {
        return (message.messageCode() == uint8(MessageType.MessageProof))
            ? message.deserializeMessageProof().hash
            : bytes32(0);
    }

    function createMessageProof(bytes calldata message) external pure returns (bytes memory) {
        return MessageLib.MessageProof({hash: keccak256(message)}).serialize();
    }
}

contract GatewayTest is Test {
    using CastLib for *;
    using MessageLib for *;

    uint16 constant LOCAL_CENTRIFUGE_ID = 23;
    uint16 constant REMOTE_CENTRIFUGE_ID = 24;
    PoolId immutable POOL_A = newPoolId(LOCAL_CENTRIFUGE_ID, 42);
    uint256 constant INITIAL_BALANCE = 1 ether;

    uint256 constant FIRST_ADAPTER_ESTIMATE = 1.5 gwei;
    uint256 constant SECOND_ADAPTER_ESTIMATE = 1 gwei;
    uint256 constant THIRD_ADAPTER_ESTIMATE = 0.5 gwei;
    uint256 constant BASE_MESSAGE_ESTIMATE = 0.75 gwei;
    uint256 constant BASE_PROOF_ESTIMATE = 0.25 gwei;

    address self;

    MockRoot root;
    MockProcessor handler;
    MockGasService gasService;
    MockAdapter adapter1;
    MockAdapter adapter2;
    MockAdapter adapter3;
    MockAdapter adapter4;
    IAdapter[] oneMockAdapter;
    IAdapter[] twoDuplicateMockAdapters;
    IAdapter[] threeMockAdapters;
    IAdapter[] fourMockAdapters;
    IAdapter[] nineMockAdapters;
    Gateway gateway;

    function setUp() public {
        self = address(this);
        root = new MockRoot();
        handler = new MockProcessor();
        gasService = new MockGasService();
        gateway = new Gateway(LOCAL_CENTRIFUGE_ID, IRoot(address(root)), IGasService(address(gasService)));
        gateway.file("processor", address(handler));

        adapter1 = new MockAdapter(REMOTE_CENTRIFUGE_ID, gateway);
        vm.label(address(adapter1), "MockAdapter1");
        adapter2 = new MockAdapter(REMOTE_CENTRIFUGE_ID, gateway);
        vm.label(address(adapter2), "MockAdapter2");
        adapter3 = new MockAdapter(REMOTE_CENTRIFUGE_ID, gateway);
        vm.label(address(adapter3), "MockAdapter3");
        adapter4 = new MockAdapter(REMOTE_CENTRIFUGE_ID, gateway);
        vm.label(address(adapter4), "MockAdapter4");

        adapter1.setReturn("estimate", FIRST_ADAPTER_ESTIMATE);
        adapter2.setReturn("estimate", SECOND_ADAPTER_ESTIMATE);
        adapter3.setReturn("estimate", THIRD_ADAPTER_ESTIMATE);

        gasService.setReturn("message_estimate", BASE_MESSAGE_ESTIMATE);
        gasService.setReturn("proof_estimate", BASE_PROOF_ESTIMATE);

        oneMockAdapter.push(adapter1);

        threeMockAdapters.push(adapter1);
        threeMockAdapters.push(adapter2);
        threeMockAdapters.push(adapter3);

        twoDuplicateMockAdapters.push(adapter1);
        twoDuplicateMockAdapters.push(adapter1);

        fourMockAdapters.push(adapter1);
        fourMockAdapters.push(adapter2);
        fourMockAdapters.push(adapter3);
        fourMockAdapters.push(adapter4);

        nineMockAdapters.push(adapter1);
        nineMockAdapters.push(adapter1);
        nineMockAdapters.push(adapter1);
        nineMockAdapters.push(adapter1);
        nineMockAdapters.push(adapter1);
        nineMockAdapters.push(adapter1);
        nineMockAdapters.push(adapter1);
        nineMockAdapters.push(adapter1);
        nineMockAdapters.push(adapter1);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(IGateway.FileUnrecognizedParam.selector);
        gateway.file("random", self);

        assertEq(address(gateway.processor()), address(handler));
        assertEq(address(gateway.gasService()), address(gasService));

        // success
        gateway.file("processor", self);
        assertEq(address(gateway.processor()), self);
        gateway.file("gasService", self);
        assertEq(address(gateway.gasService()), self);

        // remove self from wards
        gateway.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.file("processor", self);
    }

    // --- Permissions ---
    function testOnlyAdaptersCanCall() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory message = MessageLib.NotifyPool(1).serialize();

        vm.expectRevert(IGateway.InvalidAdapter.selector);
        vm.prank(makeAddr("randomUser"));
        gateway.handle(REMOTE_CENTRIFUGE_ID, message);

        //success
        vm.prank(address(adapter1));
        gateway.handle(REMOTE_CENTRIFUGE_ID, message);
    }

    function testFileAdapters() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);
        assertEq(gateway.quorum(REMOTE_CENTRIFUGE_ID), 3);
        assertEq(address(gateway.adapters(REMOTE_CENTRIFUGE_ID, 0)), address(adapter1));
        assertEq(address(gateway.adapters(REMOTE_CENTRIFUGE_ID, 1)), address(adapter2));
        assertEq(address(gateway.adapters(REMOTE_CENTRIFUGE_ID, 2)), address(adapter3));
        assertEq(gateway.activeSessionId(REMOTE_CENTRIFUGE_ID), 0);

        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, fourMockAdapters);
        assertEq(gateway.quorum(REMOTE_CENTRIFUGE_ID), 4);
        assertEq(address(gateway.adapters(REMOTE_CENTRIFUGE_ID, 0)), address(adapter1));
        assertEq(address(gateway.adapters(REMOTE_CENTRIFUGE_ID, 1)), address(adapter2));
        assertEq(address(gateway.adapters(REMOTE_CENTRIFUGE_ID, 2)), address(adapter3));
        assertEq(address(gateway.adapters(REMOTE_CENTRIFUGE_ID, 3)), address(adapter4));
        assertEq(gateway.activeSessionId(REMOTE_CENTRIFUGE_ID), 1);

        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);
        assertEq(gateway.quorum(REMOTE_CENTRIFUGE_ID), 3);
        assertEq(address(gateway.adapters(REMOTE_CENTRIFUGE_ID, 0)), address(adapter1));
        assertEq(address(gateway.adapters(REMOTE_CENTRIFUGE_ID, 1)), address(adapter2));
        assertEq(address(gateway.adapters(REMOTE_CENTRIFUGE_ID, 2)), address(adapter3));
        assertEq(gateway.activeSessionId(REMOTE_CENTRIFUGE_ID), 2);
        vm.expectRevert(bytes(""));
        assertEq(address(gateway.adapters(REMOTE_CENTRIFUGE_ID, 3)), address(0));

        vm.expectRevert(IGateway.ExceedsMax.selector);
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, nineMockAdapters);

        vm.expectRevert(IGateway.FileUnrecognizedParam.selector);
        gateway.file("notAdapters", REMOTE_CENTRIFUGE_ID, nineMockAdapters);

        vm.expectRevert(IGateway.NoDuplicatesAllowed.selector);
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, twoDuplicateMockAdapters);

        gateway.deny(address(this));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);
    }

    function testUseBeforeInitialization() public {
        bytes memory message = MessageLib.NotifyPool(1).serialize();

        vm.expectRevert(IGateway.InvalidAdapter.selector);
        gateway.handle(REMOTE_CENTRIFUGE_ID, message);

        vm.expectRevert(IGateway.EmptyAdapterSet.selector);
        gateway.send(REMOTE_CENTRIFUGE_ID, message);
    }

    function testIncomingAggregatedMessages() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory firstMessage = MessageLib.NotifyPool(1).serialize();
        bytes memory firstProof = _formatMessageProof(firstMessage);

        vm.expectRevert(IGateway.InvalidAdapter.selector);
        gateway.handle(REMOTE_CENTRIFUGE_ID, firstMessage);

        // Executes after quorum is reached
        _send(adapter1, firstMessage);
        assertEq(handler.received(firstMessage), 0);
        assertVotes(firstMessage, 1, 0, 0);

        _send(adapter2, firstProof);
        assertEq(handler.received(firstMessage), 0);
        assertVotes(firstMessage, 1, 1, 0);

        _send(adapter3, firstProof);
        assertEq(handler.received(firstMessage), 1);
        assertVotes(firstMessage, 0, 0, 0);

        // Resending same message works
        _send(adapter1, firstMessage);
        assertEq(handler.received(firstMessage), 1);
        assertVotes(firstMessage, 1, 0, 0);

        _send(adapter2, firstProof);
        assertEq(handler.received(firstMessage), 1);
        assertVotes(firstMessage, 1, 1, 0);

        _send(adapter3, firstProof);
        assertEq(handler.received(firstMessage), 2);
        assertVotes(firstMessage, 0, 0, 0);

        // Sending another message works
        bytes memory secondMessage = MessageLib.NotifyPool(2).serialize();
        bytes memory secondProof = _formatMessageProof(secondMessage);

        _send(adapter1, secondMessage);
        assertEq(handler.received(secondMessage), 0);
        assertVotes(secondMessage, 1, 0, 0);

        _send(adapter2, secondProof);
        assertEq(handler.received(secondMessage), 0);
        assertVotes(secondMessage, 1, 1, 0);

        _send(adapter3, secondProof);
        assertEq(handler.received(secondMessage), 1);
        assertVotes(secondMessage, 0, 0, 0);

        // Swapping order of message vs proofs works
        bytes memory thirdMessage = MessageLib.NotifyPool(3).serialize();
        bytes memory thirdProof = _formatMessageProof(thirdMessage);

        _send(adapter2, thirdProof);
        assertEq(handler.received(thirdMessage), 0);
        assertVotes(thirdMessage, 0, 1, 0);

        _send(adapter3, thirdProof);
        assertEq(handler.received(thirdMessage), 0);
        assertVotes(thirdMessage, 0, 1, 1);

        _send(adapter1, thirdMessage);
        assertEq(handler.received(thirdMessage), 1);
        assertVotes(thirdMessage, 0, 0, 0);
    }

    function testQuorumOfOne() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, oneMockAdapter);

        bytes memory message = MessageLib.NotifyPool(1).serialize();

        // Executes immediately
        _send(adapter1, message);
        assertEq(handler.received(message), 1);
    }

    function testOneFasterPayloadAdapter() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory message = MessageLib.NotifyPool(1).serialize();
        bytes memory proof = _formatMessageProof(message);

        vm.expectRevert(IGateway.InvalidAdapter.selector);
        gateway.handle(REMOTE_CENTRIFUGE_ID, message);

        // Confirm two messages by payload first
        _send(adapter1, message);
        _send(adapter1, message);
        assertEq(handler.received(message), 0);
        assertVotes(message, 2, 0, 0);

        // Submit first proof
        _send(adapter2, proof);
        assertEq(handler.received(message), 0);
        assertVotes(message, 2, 1, 0);

        // Submit second proof
        _send(adapter3, proof);
        assertEq(handler.received(message), 1);
        assertVotes(message, 1, 0, 0);

        // Submit third proof
        _send(adapter2, proof);
        assertEq(handler.received(message), 1);
        assertVotes(message, 1, 1, 0);

        // Submit fourth proof
        _send(adapter3, proof);
        assertEq(handler.received(message), 2);
        assertVotes(message, 0, 0, 0);
    }

    function testVotesExpireAfterSession() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, fourMockAdapters);

        bytes memory message = MessageLib.NotifyPool(1).serialize();
        bytes memory proof = _formatMessageProof(message);

        _send(adapter1, message);
        _send(adapter2, proof);
        assertEq(handler.received(message), 0);
        assertVotes(message, 1, 1, 0);

        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        adapter3.execute(proof);
        assertEq(handler.received(message), 0);
        assertVotes(message, 0, 0, 1);
    }

    function testOutgoingAggregatedMessages() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory message = MessageLib.NotifyPool(1).serialize();
        bytes memory proof = _formatMessageProof(message);

        assertEq(adapter1.sent(message), 0);
        assertEq(adapter2.sent(message), 0);
        assertEq(adapter3.sent(message), 0);
        assertEq(adapter1.sent(proof), 0);
        assertEq(adapter2.sent(proof), 0);
        assertEq(adapter3.sent(proof), 0);

        gateway.send(REMOTE_CENTRIFUGE_ID, message);

        assertEq(adapter1.sent(message), 1);
        assertEq(adapter2.sent(message), 0);
        assertEq(adapter3.sent(message), 0);
        assertEq(adapter1.sent(proof), 0);
        assertEq(adapter2.sent(proof), 1);
        assertEq(adapter3.sent(proof), 1);
    }

    function testPrepayment() public {
        uint256 topUpAmount = 1 gwei;

        gateway.payTransaction{value: 0}(address(this));

        uint256 balanceBeforeTopUp = address(gateway).balance;
        gateway.payTransaction{value: topUpAmount}(address(this));
        uint256 balanceAfterTopUp = address(gateway).balance;
        assertEq(balanceAfterTopUp, balanceBeforeTopUp + topUpAmount);
    }

    function testOutgoingMessagingWithNotEnoughPrepayment() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory message = MessageLib.NotifyPool(1).serialize();
        bytes memory proof = _formatMessageProof(message);

        uint256 balanceBeforeTx = address(gateway).balance;
        uint256 topUpAmount = 10 wei;

        gateway.payTransaction{value: topUpAmount}(address(this));

        vm.expectRevert(IGateway.NotEnoughTransactionGas.selector);
        gateway.send(REMOTE_CENTRIFUGE_ID, message);

        assertEq(adapter1.calls("pay"), 0);
        assertEq(adapter2.calls("pay"), 0);
        assertEq(adapter3.calls("pay"), 0);

        assertEq(adapter1.sent(message), 0);
        assertEq(adapter2.sent(proof), 0);
        assertEq(adapter3.sent(proof), 0);

        assertEq(address(gateway).balance, balanceBeforeTx + topUpAmount);
    }

    function testOutgoingMessagingWithPrepayment() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory message = MessageLib.NotifyPool(1).serialize();
        bytes memory proof = _formatMessageProof(message);

        uint256 balanceBeforeTx = address(gateway).balance;

        (uint256[] memory tokens, uint256 total) = gateway.estimate(REMOTE_CENTRIFUGE_ID, message);
        gateway.payTransaction{value: total}(address(this));

        gateway.send(REMOTE_CENTRIFUGE_ID, message);

        for (uint256 i; i < threeMockAdapters.length; i++) {
            MockAdapter currentAdapter = MockAdapter(address(threeMockAdapters[i]));
            uint256[] memory metadata = currentAdapter.callsWithValue("send");
            assertEq(metadata.length, 1);
            assertEq(metadata[0], tokens[i]);

            assertEq(currentAdapter.sent(i == 0 ? message : proof), 1);
        }
        assertEq(address(gateway).balance, balanceBeforeTx);

        uint256 fuel = uint256(vm.load(address(gateway), bytes32(0x0)));
        assertEq(fuel, 0);
    }

    function testOutgoingMessagingWithExtraPrepayment() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory message = MessageLib.NotifyPool(1).serialize();
        bytes memory proof = _formatMessageProof(message);

        uint256 balanceBeforeTx = address(gateway).balance;

        (uint256[] memory tokens, uint256 total) = gateway.estimate(REMOTE_CENTRIFUGE_ID, message);
        uint256 extra = 10 wei;
        uint256 topUpAmount = total + extra;
        gateway.payTransaction{value: topUpAmount}(address(this));

        gateway.send(REMOTE_CENTRIFUGE_ID, message);

        for (uint256 i; i < threeMockAdapters.length; i++) {
            MockAdapter currentAdapter = MockAdapter(address(threeMockAdapters[i]));
            uint256[] memory metadata = currentAdapter.callsWithValue("send");
            assertEq(metadata.length, 1);
            assertEq(metadata[0], tokens[i]);

            assertEq(currentAdapter.sent(i == 0 ? message : proof), 1);
        }
        assertEq(address(gateway).balance, balanceBeforeTx + extra);
        uint256 fuel = uint256(vm.load(address(gateway), bytes32(0x0)));
        assertEq(fuel, 0);
    }

    function testingOutgoingMessagingWithCoveredPayment() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory message = MessageLib.NotifyPool(POOL_A.raw()).serialize();
        bytes memory proof = _formatMessageProof(message);

        (uint256[] memory tokens, uint256 total) = gateway.estimate(REMOTE_CENTRIFUGE_ID, message);

        assertEq(gateway.fuel(), 0);

        gateway.subsidizePool{value: total}(POOL_A);
        gateway.send(REMOTE_CENTRIFUGE_ID, message);

        for (uint256 i; i < threeMockAdapters.length; i++) {
            MockAdapter currentAdapter = MockAdapter(address(threeMockAdapters[i]));
            uint256[] memory metadata = currentAdapter.callsWithValue("send");
            assertEq(metadata.length, 1);
            assertEq(metadata[0], tokens[i]);

            assertEq(currentAdapter.sent(i == 0 ? message : proof), 1);
        }
        assertEq(address(gateway).balance, 0);
        assertEq(gateway.fuel(), 0);
    }

    function testingOutgoingMessagingWithPartiallyCoveredPayment() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory message = MessageLib.NotifyPool(POOL_A.raw()).serialize();
        bytes memory proof = _formatMessageProof(message);

        (uint256[] memory tokens,) = gateway.estimate(REMOTE_CENTRIFUGE_ID, message);

        uint256 fundsToCoverTwoAdaptersOnly = tokens[0] + tokens[1];

        assertEq(gateway.fuel(), 0);

        gateway.subsidizePool{value: fundsToCoverTwoAdaptersOnly}(POOL_A);
        gateway.send(REMOTE_CENTRIFUGE_ID, message);

        uint256[] memory r1Metadata = adapter1.callsWithValue("send");
        assertEq(r1Metadata.length, 1);
        assertEq(r1Metadata[0], tokens[0]);
        assertEq(adapter1.sent(message), 1);

        uint256[] memory r2Metadata = adapter2.callsWithValue("send");
        assertEq(r2Metadata.length, 1);
        assertEq(r2Metadata[0], tokens[1]);
        assertEq(adapter2.sent(proof), 1);

        uint256[] memory r3Metadata = adapter3.callsWithValue("send");
        assertEq(r3Metadata.length, 1);
        assertEq(r3Metadata[0], 0);
        assertEq(adapter3.sent(proof), 1);

        assertEq(address(gateway).balance, 0);
        assertEq(gateway.fuel(), 0);
    }

    function testingOutgoingMessagingWithoutBeingCovered() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory message = MessageLib.NotifyPool(POOL_A.raw()).serialize();
        bytes memory proof = _formatMessageProof(message);

        vm.deal(address(gateway), 0);

        assertEq(gateway.fuel(), 0);

        gateway.send(REMOTE_CENTRIFUGE_ID, message);

        uint256[] memory r1Metadata = adapter1.callsWithValue("send");
        assertEq(r1Metadata.length, 1);
        assertEq(r1Metadata[0], 0);
        assertEq(adapter1.sent(message), 1);

        uint256[] memory r2Metadata = adapter2.callsWithValue("send");
        assertEq(r2Metadata.length, 1);
        assertEq(r2Metadata[0], 0);
        assertEq(adapter2.sent(proof), 1);

        uint256[] memory r3Metadata = adapter3.callsWithValue("send");
        assertEq(r3Metadata.length, 1);
        assertEq(r3Metadata[0], 0);
        assertEq(adapter3.sent(proof), 1);

        assertEq(gateway.fuel(), 0);
    }

    function testRecoverFailedMessage() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory message = MessageLib.NotifyPool(POOL_A.raw()).serialize();
        bytes memory proof = _formatMessageProof(message);

        // Only send through 2 out of 3 adapters
        adapter2.execute(proof);
        adapter3.execute(proof);
        assertEq(handler.received(message), 0);

        vm.expectRevert(IGateway.MessageRecoveryNotInitiated.selector);
        gateway.executeMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter1, message);

        // Initiate recovery
        gateway.initiateMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter1, keccak256(message));
        /* TODO: move to integration tests
        _send(
            adapter2,
        MessageLib.InitiateMessageRecovery(keccak256(message), address(adapter1).toBytes32(), REMOTE_CENTRIFUGE_ID)
                .serialize()
        );
        */

        vm.expectRevert(IGateway.MessageRecoveryChallengePeriodNotEnded.selector);
        gateway.executeMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter1, message);

        // Execute recovery
        vm.warp(block.timestamp + gateway.RECOVERY_CHALLENGE_PERIOD());
        gateway.executeMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter1, message);
        assertEq(handler.received(message), 1);
    }

    function testRecoverFailedProof() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory message = MessageLib.NotifyPool(POOL_A.raw()).serialize();
        bytes memory proof = _formatMessageProof(message);

        // Only send through 2 out of 3 adapters
        adapter1.execute(message);
        adapter2.execute(proof);
        _send(adapter1, message);
        _send(adapter2, proof);
        assertEq(handler.received(message), 0);

        vm.expectRevert(IGateway.MessageRecoveryNotInitiated.selector);
        gateway.executeMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter3, proof);

        // Initiate recovery
        gateway.initiateMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter3, keccak256(proof));
        /* TODO: move to integration tests
        _send(
            adapter1,
        MessageLib.InitiateMessageRecovery(keccak256(proof), address(adapter3).toBytes32(), REMOTE_CENTRIFUGE_ID)
                .serialize()
        );
        */

        vm.expectRevert(IGateway.MessageRecoveryChallengePeriodNotEnded.selector);
        gateway.executeMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter3, proof);
        vm.warp(block.timestamp + gateway.RECOVERY_CHALLENGE_PERIOD());

        // Execute recovery
        gateway.executeMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter3, proof);
        assertEq(handler.received(message), 1);
    }

    function testCannotRecoverInvalidAdapter() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory message = MessageLib.NotifyPool(POOL_A.raw()).serialize();
        bytes memory proof = _formatMessageProof(message);

        // Only send through 2 out of 3 adapters
        _send(adapter1, message);
        _send(adapter2, proof);
        assertEq(handler.received(message), 0);

        // Initiate recovery
        gateway.initiateMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter3, keccak256(proof));
        /* // TODO: move to integration tests
        _send(
            adapter1,
        MessageLib.InitiateMessageRecovery(keccak256(proof), address(adapter3).toBytes32(), REMOTE_CENTRIFUGE_ID)
                .serialize()
        );
        */

        vm.warp(block.timestamp + gateway.RECOVERY_CHALLENGE_PERIOD());

        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, oneMockAdapter);

        vm.expectRevert(IGateway.InvalidAdapter.selector);
        gateway.executeMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter3, proof);

        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);
    }

    function testDisputeRecovery() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory message = MessageLib.NotifyPool(POOL_A.raw()).serialize();
        bytes memory proof = _formatMessageProof(message);

        // Only send through 2 out of 3 adapters
        _send(adapter1, message);
        _send(adapter2, proof);
        assertEq(handler.received(message), 0);

        // Initiate recovery
        gateway.initiateMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter3, keccak256(proof));
        /* TODO: move to integration tests
        _send(
            adapter1,
        MessageLib.InitiateMessageRecovery(keccak256(proof), address(adapter3).toBytes32(), REMOTE_CENTRIFUGE_ID)
                .serialize()
        );
        */

        vm.expectRevert(IGateway.MessageRecoveryChallengePeriodNotEnded.selector);
        gateway.executeMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter3, proof);

        // Dispute recovery
        gateway.disputeMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter3, keccak256(proof));
        /* TODO: move to integration tests
        _send(
            adapter2,
        MessageLib.DisputeMessageRecovery(keccak256(proof), address(adapter3).toBytes32(), REMOTE_CENTRIFUGE_ID)
                .serialize()
        );
        */

        // Check that recovery is not possible anymore
        vm.expectRevert(IGateway.MessageRecoveryNotInitiated.selector);
        gateway.executeMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter3, proof);
        assertEq(handler.received(message), 0);
    }

    function testRecursiveRecoveryMessageFails() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory message =
            MessageLib.DisputeMessageRecovery(keccak256(""), bytes32(0), REMOTE_CENTRIFUGE_ID).serialize();
        bytes memory proof = _formatMessageProof(message);

        _send(adapter2, proof);
        _send(adapter3, proof);
        assertEq(handler.received(message), 0);

        gateway.initiateMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter1, keccak256(message));
        /* TODO: move to integration tests
        _send(
            adapter2,
        MessageLib.InitiateMessageRecovery(keccak256(message), address(adapter1).toBytes32(), REMOTE_CENTRIFUGE_ID)
                .serialize()
        );
        */

        vm.warp(block.timestamp + gateway.RECOVERY_CHALLENGE_PERIOD());

        vm.expectRevert(IGateway.RecoveryMessageRecovered.selector);
        gateway.executeMessageRecovery(REMOTE_CENTRIFUGE_ID, adapter1, message);
        assertEq(handler.received(message), 0);
    }

    function testMessagesCannotBeReplayed(uint8 numAdapters, uint8 numParallelDuplicateMessages_, uint256 entropy)
        public
    {
        numAdapters = uint8(bound(numAdapters, 1, gateway.MAX_ADAPTER_COUNT()));
        uint16 numParallelDuplicateMessages = uint16(bound(numParallelDuplicateMessages_, 1, 255));

        bytes memory message = MessageLib.NotifyPool(POOL_A.raw()).serialize();
        bytes memory proof = _formatMessageProof(message);

        // Setup random set of adapters
        IAdapter[] memory testAdapters = new IAdapter[](numAdapters);
        for (uint256 i = 0; i < numAdapters; i++) {
            testAdapters[i] = new MockAdapter(REMOTE_CENTRIFUGE_ID, gateway);
        }
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, testAdapters);

        // Generate random sequence of confirming messages and proofs
        uint256 it = 0;
        uint256 totalSent = 0;
        uint256[] memory sentPerAdapter = new uint256[](numAdapters);
        while (totalSent < numParallelDuplicateMessages * numAdapters) {
            it++;
            uint8 randomAdapterId =
                numAdapters > 1 ? uint8(uint256(keccak256(abi.encodePacked(entropy, it)))) % numAdapters : 0;

            if (sentPerAdapter[randomAdapterId] == numParallelDuplicateMessages) {
                // Already confirmed all the messages
                continue;
            }

            // Send the message or proof
            if (randomAdapterId == 0) {
                _send(testAdapters[randomAdapterId], message);
            } else {
                _send(testAdapters[randomAdapterId], proof);
            }

            totalSent++;
            sentPerAdapter[randomAdapterId]++;
        }

        // Check that each message was confirmed exactly numParallelDuplicateMessages times
        for (uint256 j = 0; j < numParallelDuplicateMessages; j++) {
            assertEq(handler.received(message), numParallelDuplicateMessages);
        }
    }

    function testEstimate() public {
        gateway.file("adapters", REMOTE_CENTRIFUGE_ID, threeMockAdapters);

        bytes memory message = MessageLib.NotifyPool(POOL_A.raw()).serialize();

        uint256 firstRouterEstimate = FIRST_ADAPTER_ESTIMATE + BASE_MESSAGE_ESTIMATE;
        uint256 secondRouterEstimate = SECOND_ADAPTER_ESTIMATE + BASE_PROOF_ESTIMATE;
        uint256 thirdRouterEstimate = THIRD_ADAPTER_ESTIMATE + BASE_PROOF_ESTIMATE;
        uint256 totalEstimate = firstRouterEstimate + secondRouterEstimate + thirdRouterEstimate;

        (uint256[] memory tokens, uint256 total) = gateway.estimate(REMOTE_CENTRIFUGE_ID, message);

        assertEq(tokens.length, 3);
        assertEq(tokens[0], firstRouterEstimate);
        assertEq(tokens[1], secondRouterEstimate);
        assertEq(tokens[2], thirdRouterEstimate);
        assertEq(total, totalEstimate);
    }

    function assertVotes(bytes memory message, uint16 r1, uint16 r2, uint16 r3) internal view {
        uint16[8] memory votes = gateway.votes(REMOTE_CENTRIFUGE_ID, keccak256(message));
        assertEq(votes[0], r1);
        assertEq(votes[1], r2);
        assertEq(votes[2], r3);
    }

    /// @notice Returns the smallest of two numbers.
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? b : a;
    }

    function _countValues(uint16[8] memory arr) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < arr.length; ++i) {
            count += arr[i];
        }
    }

    function _formatMessageProof(bytes memory message) internal pure returns (bytes memory) {
        return MessageLib.MessageProof(keccak256(message)).serialize();
    }

    function _formatMessageProof(bytes32 messageHash) internal pure returns (bytes memory) {
        return MessageLib.MessageProof(messageHash).serialize();
    }

    /// @dev Use to simulate incoming message to the gateway sent by a adapter.
    function _send(IAdapter adapter, bytes memory message) internal {
        vm.prank(address(adapter));
        gateway.handle(REMOTE_CENTRIFUGE_ID, message);
    }
}
