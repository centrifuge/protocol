// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/Auth.sol";
import {BytesLib} from "../../../src/misc/libraries/BytesLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {MultiAdapter} from "../../../src/core/messaging/MultiAdapter.sol";
import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {MessageType} from "../../../src/core/messaging/libraries/MessageLib.sol";
import {IMessageHandler} from "../../../src/core/messaging/interfaces/IMessageHandler.sol";
import {IMessageProperties} from "../../../src/core/messaging/interfaces/IMessageProperties.sol";
import {IMultiAdapter, MAX_ADAPTER_COUNT} from "../../../src/core/messaging/interfaces/IMultiAdapter.sol";

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

    function messagePoolId(bytes calldata message) external pure returns (PoolId) {
        return _poolId(message);
    }

    function routePoolId(bytes calldata message, bool poolConfigured) external pure returns (PoolId) {
        // A SetPoolAdapters (first byte == the message kind) for an unconfigured pool falls back to global.
        if (!poolConfigured && message.length >= 1 && uint8(message[0]) == uint8(MessageType.SetPoolAdapters)) {
            return PoolId.wrap(0);
        }
        return _poolId(message);
    }

    function _poolId(bytes calldata message) internal pure returns (PoolId) {
        // A SetPoolAdapters message (first byte == the message kind) targets POOL_A in these tests.
        if (message.length >= 1 && uint8(message[0]) == uint8(MessageType.SetPoolAdapters)) return POOL_A;
        if (message.length >= 6) {
            bytes memory prefix = message[0:6];
            if (keccak256(prefix) == keccak256("POOL_A")) return POOL_A;
            revert("Unreachable: message with pool but not POOL_A");
        }
        return PoolId.wrap(0);
    }

    function messageProcessingGasLimit(uint16, bytes calldata message) external pure returns (uint128) {}

    function messageOverallGasLimit(uint16, bytes calldata message) external pure returns (uint128) {}

    function maxBatchGasLimit(uint16 centrifugeId) external view returns (uint128) {}

    function messageFailureGasReserve() external pure returns (uint128) {}
}

// -----------------------------------------
//     CONTRACT EXTENSION
// -----------------------------------------

contract MultiAdapterExt is MultiAdapter {
    constructor(uint16 localCentrifugeId_, IMessageHandler gateway_, address deployer)
        MultiAdapter(localCentrifugeId_, gateway_, deployer)
    {}

    function adapterDetails(uint16 centrifugeId, PoolId poolId, uint16 sessionId, IAdapter adapter)
        public
        view
        returns (IMultiAdapter.Adapter memory)
    {
        return _adapterDetails[centrifugeId][poolId][sessionId][adapter];
    }

    function setActiveSessionId(uint16 centrifugeId, PoolId poolId, uint16 sessionId) public {
        activeSessionId[centrifugeId][poolId] = sessionId;
    }

    function adaptersLength(uint16 centrifugeId, PoolId poolId, uint16 sessionId) public view returns (uint256) {
        return adapters[centrifugeId][poolId][sessionId].length;
    }
}

// -----------------------------------------
//     TESTS
// -----------------------------------------

contract MultiAdapterTest is Test {
    uint16 constant LOCAL_CENT_ID = 23;
    uint16 constant REMOTE_CENT_ID = 24;

    uint256 constant ADAPTER_ESTIMATE_1 = 15;
    uint256 constant ADAPTER_ESTIMATE_2 = 10;
    uint256 constant ADAPTER_ESTIMATE_3 = 5;

    bytes32 constant ADAPTER_DATA_1 = bytes32("data1");
    bytes32 constant ADAPTER_DATA_2 = bytes32("data2");
    bytes32 constant ADAPTER_DATA_3 = bytes32("data3");

    uint256 constant GAS_LIMIT = 10.0 gwei;

    bytes constant MESSAGE_1 = "POOL_A: Message 1";
    bytes constant MESSAGE_2 = "POOL_A: Message 2";
    bytes constant MESSAGE_POOL_0 = "Message";
    // A SetPoolAdapters message for POOL_A: first byte is the message kind (5), rest is filler.
    bytes constant SET_POOL_ADAPTERS_MSG = hex"05a1b2c3d4e5f6";

    address immutable MANAGER = makeAddr("Manager");

    IAdapter adapter1 = IAdapter(makeAddr("Adapter1"));
    IAdapter adapter2 = IAdapter(makeAddr("Adapter2"));
    IAdapter adapter3 = IAdapter(makeAddr("Adapter3"));
    IAdapter[] zeroAdapters = new IAdapter[](0);
    IAdapter[] oneAdapter;
    IAdapter[] threeAdapters;

    MockGateway gateway = new MockGateway();
    MockMessageProperties messageProperties = new MockMessageProperties();
    MultiAdapterExt multiAdapter = new MultiAdapterExt(LOCAL_CENT_ID, gateway, address(this));

    address immutable ANY = makeAddr("ANY");
    address immutable REFUND = makeAddr("REFUND");

    function _wrap(uint16 sessionId, bytes memory message) internal pure returns (bytes memory) {
        return abi.encodePacked(sessionId, message);
    }

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

    function assertVotes(uint16 sessionId, bytes memory message, int16 r1, int16 r2, int16 r3) internal view {
        int16[8] memory votes = multiAdapter.votes(REMOTE_CENT_ID, keccak256(_wrap(sessionId, message)));
        assertEq(votes[0], r1);
        assertEq(votes[1], r2);
        assertEq(votes[2], r3);
    }

    function setUp() public {
        oneAdapter.push(adapter1);
        threeAdapters.push(adapter1);
        threeAdapters.push(adapter2);
        threeAdapters.push(adapter3);

        multiAdapter.file("messageProperties", address(messageProperties));
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

contract MultiAdapterTestSetAdapters is MultiAdapterTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, new IAdapter[](0), 0, 0);
    }

    function testErrExceedsMax() public {
        IAdapter[] memory tooMuchAdapters = new IAdapter[](MAX_ADAPTER_COUNT + 1);
        vm.expectRevert(IMultiAdapter.ExceedsMax.selector);
        multiAdapter.setAdapters(
            REMOTE_CENT_ID, POOL_A, tooMuchAdapters, uint8(tooMuchAdapters.length), uint8(tooMuchAdapters.length)
        );
    }

    function testErrThresholdHigherThanQuorum() public {
        vm.expectRevert(IMultiAdapter.ThresholdHigherThanQuorum.selector);
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, uint8(threeAdapters.length + 1), 0);
    }

    function testErrRecoveryIndexHigherThanQuorum() public {
        vm.expectRevert(IMultiAdapter.RecoveryIndexHigherThanQuorum.selector);
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 0, uint8(threeAdapters.length + 1));
    }

    function testErrNoDuplicatedAllowed() public {
        IAdapter[] memory duplicatedAdapters = new IAdapter[](2);
        duplicatedAdapters[0] = IAdapter(address(10));
        duplicatedAdapters[1] = IAdapter(address(10));

        vm.expectRevert(IMultiAdapter.NoDuplicatesAllowed.selector);
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, duplicatedAdapters, 0, 0);
    }

    function testMultiAdapterSetAdapters() public {
        vm.expectEmit();
        emit IMultiAdapter.SetAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 1, 2);
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 1, 2);

        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_A), 1);
        assertEq(multiAdapter.quorum(REMOTE_CENT_ID, POOL_A), threeAdapters.length);
        assertEq(multiAdapter.threshold(REMOTE_CENT_ID, POOL_A), 1);
        assertEq(multiAdapter.recoveryIndex(REMOTE_CENT_ID, POOL_A), 2);

        for (uint256 i; i < threeAdapters.length; i++) {
            IMultiAdapter.Adapter memory adapter =
                multiAdapter.adapterDetails(REMOTE_CENT_ID, POOL_A, 1, threeAdapters[i]);

            assertEq(adapter.id, i + 1);
            assertEq(adapter.quorum, threeAdapters.length);
            assertEq(address(multiAdapter.adapters(REMOTE_CENT_ID, POOL_A, 1, i)), address(threeAdapters[i]));
        }
    }

    function testMultiAdapterSetAdaptersAdvanceSession() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_A), 1);

        // not increment: different chain
        multiAdapter.setAdapters(LOCAL_CENT_ID, POOL_A, threeAdapters, 3, 3);
        assertEq(multiAdapter.activeSessionId(LOCAL_CENT_ID, POOL_A), 1);

        // not increment: different pool
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_0, threeAdapters, 3, 3);
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_0), 1);

        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_0, zeroAdapters, 0, 0);
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_0), 2);

        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_0, threeAdapters, 3, 3);
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_0), 3);
    }

    function testSessionIdOverflowWrapsToOne() public {
        multiAdapter.setActiveSessionId(REMOTE_CENT_ID, POOL_A, type(uint16).max);
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_A), type(uint16).max);

        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_A), 1);
    }
}

contract MultiAdapterTestDenySession is MultiAdapterTest {
    function testErrDenySessionNotAuthorized() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);

        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        multiAdapter.denySession(REMOTE_CENT_ID, POOL_A, 1);
    }

    function testDenySession() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3); // session 1
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3); // session 2

        multiAdapter.updateManager(POOL_A, MANAGER, true);

        vm.prank(MANAGER);
        vm.expectEmit();
        emit IMultiAdapter.DenySession(REMOTE_CENT_ID, POOL_A, 1);
        multiAdapter.denySession(REMOTE_CENT_ID, POOL_A, 1);

        // Confirm session 1 messages now fail
        vm.prank(address(adapter1));
        vm.expectRevert(IMultiAdapter.InvalidAdapter.selector);
        multiAdapter.handle(REMOTE_CENT_ID, _wrap(1, MESSAGE_1));

        // Adapters array for session 1 is cleared
        assertEq(multiAdapter.adaptersLength(REMOTE_CENT_ID, POOL_A, 1), 0);
    }

    function testDenyOldSessionPreservesActiveAdapters() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3); // session 1
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3); // session 2 (active)

        multiAdapter.denySession(REMOTE_CENT_ID, POOL_A, 1);

        // Active session is still 2
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_A), 2);

        // Getters still reflect session 2's adapter configuration
        assertEq(multiAdapter.quorum(REMOTE_CENT_ID, POOL_A), 3);
        assertEq(multiAdapter.threshold(REMOTE_CENT_ID, POOL_A), 3);

        // Active adapters struct still points to session 2
        IMultiAdapter.Adapters memory active = multiAdapter.activeAdapters(REMOTE_CENT_ID, POOL_A);
        assertEq(active.sessionId, 2);
        assertEq(active.list.length, 3);

        // Adapters array for denied session 1 is cleared, session 2 is untouched
        assertEq(multiAdapter.adaptersLength(REMOTE_CENT_ID, POOL_A, 1), 0);
        assertEq(multiAdapter.adaptersLength(REMOTE_CENT_ID, POOL_A, 2), 3);
    }

    function testDenyActiveSessionClearsActiveAdapters() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3); // session 1 (active)

        multiAdapter.denySession(REMOTE_CENT_ID, POOL_A, 1);

        // Active adapters are cleared
        IMultiAdapter.Adapters memory active = multiAdapter.activeAdapters(REMOTE_CENT_ID, POOL_A);
        assertEq(active.list.length, 0);

        // Getters return 0 because there are no active adapters
        assertEq(multiAdapter.quorum(REMOTE_CENT_ID, POOL_A), 0);
        assertEq(multiAdapter.threshold(REMOTE_CENT_ID, POOL_A), 0);

        // Adapters array for the denied session is cleared
        assertEq(multiAdapter.adaptersLength(REMOTE_CENT_ID, POOL_A, 1), 0);

        // Outbound send reverts
        vm.expectRevert(IMultiAdapter.EmptyAdapterSet.selector);
        multiAdapter.send(REMOTE_CENT_ID, MESSAGE_1, GAS_LIMIT, REFUND);
    }
}

// -----------------------------------------
//     MANAGER ROLE
// -----------------------------------------

contract MultiAdapterTestUpdateManager is MultiAdapterTest {
    function testErrUpdateManagerNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        multiAdapter.updateManager(POOL_A, MANAGER, true);
    }

    function testUpdateManager() public {
        assertEq(multiAdapter.manager(POOL_A, MANAGER), false);

        vm.expectEmit();
        emit IMultiAdapter.UpdateManager(POOL_A, MANAGER, true);
        multiAdapter.updateManager(POOL_A, MANAGER, true);
        assertEq(multiAdapter.manager(POOL_A, MANAGER), true);

        vm.expectEmit();
        emit IMultiAdapter.UpdateManager(POOL_A, MANAGER, false);
        multiAdapter.updateManager(POOL_A, MANAGER, false);
        assertEq(multiAdapter.manager(POOL_A, MANAGER), false);
    }
}

contract MultiAdapterTestHandle is MultiAdapterTest {
    function testErrInvalidAdapter() public {
        vm.expectRevert(IMultiAdapter.InvalidAdapter.selector);
        multiAdapter.handle(REMOTE_CENT_ID, _wrap(0, "hi"));
    }

    function testMessageWithSeveralAdapters() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);

        bytes memory message = _wrap(1, MESSAGE_1);
        bytes32 payloadId = keccak256(abi.encodePacked(REMOTE_CENT_ID, LOCAL_CENT_ID, keccak256(message)));

        vm.prank(address(adapter1));
        vm.expectEmit();
        emit IMultiAdapter.HandlePayload(REMOTE_CENT_ID, payloadId, message, adapter1);
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(1, MESSAGE_1, 1, 0, 0);

        vm.prank(address(adapter2));
        vm.expectEmit();
        emit IMultiAdapter.HandlePayload(REMOTE_CENT_ID, payloadId, message, adapter2);
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(1, MESSAGE_1, 1, 1, 0);

        vm.prank(address(adapter3));
        vm.expectEmit();
        emit IMultiAdapter.HandlePayload(REMOTE_CENT_ID, payloadId, message, adapter3);
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertEq(gateway.handled(REMOTE_CENT_ID, 0), MESSAGE_1);
        assertVotes(1, MESSAGE_1, 0, 0, 0);
    }

    function testSameMessageAgainWithSeveralAdapters() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);

        bytes memory message = _wrap(1, MESSAGE_1);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, message);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(1, MESSAGE_1, 1, 0, 0);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(1, MESSAGE_1, 1, 1, 0);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertEq(gateway.handled(REMOTE_CENT_ID, 1), MESSAGE_1);
        assertVotes(1, MESSAGE_1, 0, 0, 0);
    }

    function testOtherMessageWithSeveralAdapters() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);

        bytes memory message1 = _wrap(1, MESSAGE_1);
        bytes memory message2 = _wrap(1, MESSAGE_2);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, message1);
        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, message1);
        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, message1);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, message2);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(1, MESSAGE_2, 1, 0, 0);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, message2);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(1, MESSAGE_2, 1, 1, 0);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, message2);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertEq(gateway.handled(REMOTE_CENT_ID, 1), MESSAGE_2);
        assertVotes(1, MESSAGE_2, 0, 0, 0);
    }

    function testOneFasterAdapter() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);

        bytes memory message = _wrap(1, MESSAGE_1);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(1, MESSAGE_1, 2, 0, 0);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(1, MESSAGE_1, 2, 1, 0);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(1, MESSAGE_1, 1, 0, 0);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(1, MESSAGE_1, 1, 1, 0);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertVotes(1, MESSAGE_1, 0, 0, 0);
    }

    function testVotesAfterNewSession() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3); // session 1

        bytes memory message1 = _wrap(1, MESSAGE_1);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, message1);
        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, message1);

        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3); // session 2

        bytes memory message2 = _wrap(2, MESSAGE_1);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, message2);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);

        // Session 1 votes are unaffected
        assertVotes(1, MESSAGE_1, 1, 1, 0);
        // Session 2 only has adapter3's vote
        assertVotes(2, MESSAGE_1, 0, 0, 1);
    }

    function testMessageWithThreshold2() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 2, 3);

        bytes memory message = _wrap(1, MESSAGE_1);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(1, MESSAGE_1, 1, 0, 0);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(1, MESSAGE_1, 0, 0, -1);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(1, MESSAGE_1, 0, 0, 0);
    }

    function testSameMessageWithThreshold2() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 2, 3);

        bytes memory message = _wrap(1, MESSAGE_1);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(1, MESSAGE_1, 1, 0, 0);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(1, MESSAGE_1, 0, 0, -1);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(1, MESSAGE_1, 0, 1, -1);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(1, MESSAGE_1, 0, 1, 0);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertVotes(1, MESSAGE_1, -1, 0, 0);
    }

    function testSameMessageWithThreshold1() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 1, 3);

        bytes memory message = _wrap(1, MESSAGE_1);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(1, MESSAGE_1, 0, -1, -1);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertVotes(1, MESSAGE_1, 0, -2, -2);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertVotes(1, MESSAGE_1, 0, -1, -2);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertVotes(1, MESSAGE_1, 0, 0, -2);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 3);
        assertVotes(1, MESSAGE_1, -1, 0, -3);
    }

    function testMessageWithThreshold2AndRecovery2() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 2, 2);

        bytes memory message = _wrap(1, MESSAGE_1);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(1, MESSAGE_1, 1, 0, 0);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(1, MESSAGE_1, 0, 0, 0); // <- vote from third adapter does not decrease below 0

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(1, MESSAGE_1, 0, 0, 1);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, message);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertVotes(1, MESSAGE_1, 0, -1, 0);
    }

    function testOldSessionMessagesStillProcessable() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3); // session 1

        bytes memory oldMsg = _wrap(1, MESSAGE_1);

        // Two votes arrive under session 1
        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, oldMsg);
        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, oldMsg);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(1, MESSAGE_1, 1, 1, 0);

        // Session advances (adapters rotated)
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3); // session 2
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_A), 2);

        // Third vote still arrives under session 1 (in-flight) — should complete
        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, oldMsg);

        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertEq(gateway.handled(REMOTE_CENT_ID, 0), MESSAGE_1);
    }

    function testNewSessionVotesAreIndependent() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3); // session 1

        // Two votes arrive under session 1
        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, _wrap(1, MESSAGE_1));
        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, _wrap(1, MESSAGE_1));
        assertVotes(1, MESSAGE_1, 1, 1, 0);

        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3); // session 2

        // Session 2 starts fresh — adapter1 vote on session 2 doesn't carry over from session 1
        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, _wrap(2, MESSAGE_1));
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(2, MESSAGE_1, 1, 0, 0);

        // Session 1 votes are still intact
        assertVotes(1, MESSAGE_1, 1, 1, 0);
    }

    function testDeniedSessionMessagesRevert() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3); // session 1
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3); // session 2

        // One vote arrives under session 1 before deny
        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, _wrap(1, MESSAGE_1));
        assertVotes(1, MESSAGE_1, 1, 0, 0);

        // Deny session 1
        multiAdapter.denySession(REMOTE_CENT_ID, POOL_A, 1);

        // Session 1 messages now rejected
        vm.prank(address(adapter2));
        vm.expectRevert(IMultiAdapter.InvalidAdapter.selector);
        multiAdapter.handle(REMOTE_CENT_ID, _wrap(1, MESSAGE_1));

        // Session 2 still works normally
        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, _wrap(2, MESSAGE_1));
        assertVotes(2, MESSAGE_1, 1, 0, 0);
    }
}

contract MultiAdapterTestSend is MultiAdapterTest {
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
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);

        bytes memory message = _wrap(1, MESSAGE_1);
        bytes32 payloadId = keccak256(abi.encodePacked(LOCAL_CENT_ID, REMOTE_CENT_ID, keccak256(message)));

        uint256 cost = GAS_LIMIT * 3 + ADAPTER_ESTIMATE_1 + ADAPTER_ESTIMATE_2 + ADAPTER_ESTIMATE_3;

        _mockAdapter(adapter1, message, ADAPTER_ESTIMATE_1, ADAPTER_DATA_1);
        _mockAdapter(adapter2, message, ADAPTER_ESTIMATE_2, ADAPTER_DATA_2);
        _mockAdapter(adapter3, message, ADAPTER_ESTIMATE_3, ADAPTER_DATA_3);

        vm.expectEmit();
        emit IMultiAdapter.SendPayload(
            REMOTE_CENT_ID,
            payloadId,
            message,
            adapter1,
            ADAPTER_DATA_1,
            GAS_LIMIT,
            GAS_LIMIT + ADAPTER_ESTIMATE_1,
            address(REFUND)
        );
        vm.expectEmit();
        emit IMultiAdapter.SendPayload(
            REMOTE_CENT_ID,
            payloadId,
            message,
            adapter2,
            ADAPTER_DATA_2,
            GAS_LIMIT,
            GAS_LIMIT + ADAPTER_ESTIMATE_2,
            address(REFUND)
        );
        vm.expectEmit();
        emit IMultiAdapter.SendPayload(
            REMOTE_CENT_ID,
            payloadId,
            message,
            adapter3,
            ADAPTER_DATA_3,
            GAS_LIMIT,
            GAS_LIMIT + ADAPTER_ESTIMATE_3,
            address(REFUND)
        );
        multiAdapter.send{value: cost}(REMOTE_CENT_ID, MESSAGE_1, GAS_LIMIT, REFUND);
    }

    /// @dev A SetPoolAdapters message for a pool with no set of its own falls back to the global set
    ///      (the init case). This is the only message type allowed to fall back.
    function testSendSetPoolAdaptersFallsBackToGlobalPool() public {
        // Only the global pool (id 0) is configured; POOL_A has no set.
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_0, oneAdapter, 1, 1);

        bytes memory message = _wrap(1, SET_POOL_ADAPTERS_MSG);
        _mockAdapter(adapter1, message, ADAPTER_ESTIMATE_1, ADAPTER_DATA_1);

        vm.expectCall(
            address(adapter1),
            GAS_LIMIT + ADAPTER_ESTIMATE_1,
            abi.encodeWithSelector(IAdapter.send.selector, REMOTE_CENT_ID, message, GAS_LIMIT, REFUND)
        );
        multiAdapter.send{value: GAS_LIMIT + ADAPTER_ESTIMATE_1}(
            REMOTE_CENT_ID, SET_POOL_ADAPTERS_MSG, GAS_LIMIT, REFUND
        );
    }

    /// @dev Once a pool configures its own set, SetPoolAdapters uses it instead of the global fallback.
    function testSendSetPoolAdaptersUsesPoolSetOverGlobal() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_0, oneAdapter, 1, 1); // global: adapter1
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3); // POOL_A: adapter1,2,3

        bytes memory message = _wrap(1, SET_POOL_ADAPTERS_MSG);
        _mockAdapter(adapter1, message, ADAPTER_ESTIMATE_1, ADAPTER_DATA_1);
        _mockAdapter(adapter2, message, ADAPTER_ESTIMATE_2, ADAPTER_DATA_2);
        _mockAdapter(adapter3, message, ADAPTER_ESTIMATE_3, ADAPTER_DATA_3);

        // adapter3 only belongs to POOL_A's set, so a call to it proves the pool set was used.
        vm.expectCall(
            address(adapter3),
            GAS_LIMIT + ADAPTER_ESTIMATE_3,
            abi.encodeWithSelector(IAdapter.send.selector, REMOTE_CENT_ID, message, GAS_LIMIT, REFUND)
        );
        uint256 cost = GAS_LIMIT * 3 + ADAPTER_ESTIMATE_1 + ADAPTER_ESTIMATE_2 + ADAPTER_ESTIMATE_3;
        multiAdapter.send{value: cost}(REMOTE_CENT_ID, SET_POOL_ADAPTERS_MSG, GAS_LIMIT, REFUND);
    }

    /// @dev Non-SetPoolAdapters messages do NOT fall back: an unconfigured pool still reverts, even when
    ///      the global set exists. The fallback is scoped to the adapter-init message only.
    function testSendNonAdapterMessageDoesNotFallBack() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_0, oneAdapter, 1, 1); // global set exists
        // POOL_A has no set; MESSAGE_1 is a regular POOL_A message, not SetPoolAdapters.
        vm.expectRevert(IMultiAdapter.EmptyAdapterSet.selector);
        multiAdapter.send(REMOTE_CENT_ID, MESSAGE_1, GAS_LIMIT, REFUND);
    }
}

contract MultiAdapterTestEstimate is MultiAdapterTest {
    function testEstimateNoAdapters() public {
        vm.expectRevert(IMultiAdapter.EmptyAdapterSet.selector);
        multiAdapter.estimate(REMOTE_CENT_ID, MESSAGE_1, GAS_LIMIT);
    }

    function testEstimate() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);

        bytes memory message = _wrap(uint16((1 << 8) + 1), MESSAGE_1);
        _mockAdapter(adapter1, message, ADAPTER_ESTIMATE_1, ADAPTER_DATA_1);
        _mockAdapter(adapter2, message, ADAPTER_ESTIMATE_2, ADAPTER_DATA_2);
        _mockAdapter(adapter3, message, ADAPTER_ESTIMATE_3, ADAPTER_DATA_3);

        uint256 estimation = GAS_LIMIT * 3 + ADAPTER_ESTIMATE_1 + ADAPTER_ESTIMATE_2 + ADAPTER_ESTIMATE_3;

        assertEq(multiAdapter.estimate(REMOTE_CENT_ID, MESSAGE_1, GAS_LIMIT), estimation);
    }
}

contract MultiAdapterTestGetters is MultiAdapterTest {
    function testGettersOnEmptyState() public view {
        assertEq(multiAdapter.quorum(REMOTE_CENT_ID, POOL_A), 0);
        assertEq(multiAdapter.threshold(REMOTE_CENT_ID, POOL_A), 0);
        assertEq(multiAdapter.recoveryIndex(REMOTE_CENT_ID, POOL_A), 0);
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_A), 0);
    }
}
