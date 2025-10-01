// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/Auth.sol";
import {BytesLib} from "../../../src/misc/libraries/BytesLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {MultiAdapter} from "../../../src/common/MultiAdapter.sol";
import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
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

    IAdapter adapter1 = IAdapter(makeAddr("Adapter1"));
    IAdapter adapter2 = IAdapter(makeAddr("Adapter2"));
    IAdapter adapter3 = IAdapter(makeAddr("Adapter3"));
    IAdapter[] oneAdapter;
    IAdapter[] threeAdapters;

    MockGateway gateway = new MockGateway();
    MockMessageProperties messageProperties = new MockMessageProperties();
    MultiAdapterExt multiAdapter = new MultiAdapterExt(LOCAL_CENT_ID, gateway, messageProperties, address(this));

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

    function assertVotes(bytes memory message, int16 r1, int16 r2, int16 r3) internal view {
        int16[8] memory votes = multiAdapter.votes(REMOTE_CENT_ID, keccak256(message));
        assertEq(votes[0], r1);
        assertEq(votes[1], r2);
        assertEq(votes[2], r3);
    }

    function setUp() public {
        oneAdapter.push(adapter1);
        threeAdapters.push(adapter1);
        threeAdapters.push(adapter2);
        threeAdapters.push(adapter3);
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

    function testErrEmptyAdapterFile() public {
        vm.expectRevert(IMultiAdapter.EmptyAdapterSet.selector);
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

        assertEq(multiAdapter.poolAdapters(REMOTE_CENT_ID, POOL_A).length, 3);
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_A), 0);
        assertEq(multiAdapter.quorum(REMOTE_CENT_ID, POOL_A), threeAdapters.length);
        assertEq(multiAdapter.threshold(REMOTE_CENT_ID, POOL_A), 1);
        assertEq(multiAdapter.recoveryIndex(REMOTE_CENT_ID, POOL_A), 2);

        for (uint256 i; i < threeAdapters.length; i++) {
            IMultiAdapter.Adapter memory adapter = multiAdapter.adapterDetails(REMOTE_CENT_ID, POOL_A, threeAdapters[i]);

            assertEq(adapter.id, i + 1);
            assertEq(adapter.quorum, threeAdapters.length);
            assertEq(adapter.activeSessionId, 0);
            assertEq(address(multiAdapter.adapters(REMOTE_CENT_ID, POOL_A, i)), address(threeAdapters[i]));
        }
    }

    function testMultiAdapterSetAdaptersAdvanceSession() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_A), 0);

        // Using another chain uses a different active session counter
        multiAdapter.setAdapters(LOCAL_CENT_ID, POOL_A, threeAdapters, 3, 3);
        assertEq(multiAdapter.activeSessionId(LOCAL_CENT_ID, POOL_A), 0);

        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);
        assertEq(multiAdapter.activeSessionId(REMOTE_CENT_ID, POOL_A), 1);
    }
}

contract MultiAdapterTestHandle is MultiAdapterTest {
    function testErrInvalidAdapter() public {
        vm.expectRevert(IMultiAdapter.InvalidAdapter.selector);
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
    }

    function testMessageWithOneAdapterButPoolANoConfigured() public {
        // POOL_A is not configured, and MESSAGE_1 comes from POOL_A, but it works because POOL_0 is the default
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_0, oneAdapter, 1, 1);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);

        assertEq(gateway.handled(REMOTE_CENT_ID, 0), MESSAGE_1);
    }

    function testMessageWithSeveralAdapters() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);

        bytes32 payloadId = keccak256(abi.encodePacked(REMOTE_CENT_ID, LOCAL_CENT_ID, keccak256(MESSAGE_1)));

        vm.prank(address(adapter1));
        vm.expectEmit();
        emit IMultiAdapter.HandlePayload(REMOTE_CENT_ID, payloadId, MESSAGE_1, adapter1);
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(MESSAGE_1, 1, 0, 0);

        vm.prank(address(adapter2));
        vm.expectEmit();
        emit IMultiAdapter.HandlePayload(REMOTE_CENT_ID, payloadId, MESSAGE_1, adapter2);
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(MESSAGE_1, 1, 1, 0);

        vm.prank(address(adapter3));
        vm.expectEmit();
        emit IMultiAdapter.HandlePayload(REMOTE_CENT_ID, payloadId, MESSAGE_1, adapter3);
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertEq(gateway.handled(REMOTE_CENT_ID, 0), MESSAGE_1);
        assertVotes(MESSAGE_1, 0, 0, 0);
    }

    function testSameMessageAgainWithSeveralAdapters() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(MESSAGE_1, 1, 0, 0);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(MESSAGE_1, 1, 1, 0);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertEq(gateway.handled(REMOTE_CENT_ID, 1), MESSAGE_1);
        assertVotes(MESSAGE_1, 0, 0, 0);
    }

    function testOtherMessageWithSeveralAdapters() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_2);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(MESSAGE_2, 1, 0, 0);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_2);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(MESSAGE_2, 1, 1, 0);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_2);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertEq(gateway.handled(REMOTE_CENT_ID, 1), MESSAGE_2);
        assertVotes(MESSAGE_2, 0, 0, 0);
    }

    function testOneFasterAdapter() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(MESSAGE_1, 2, 0, 0);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(MESSAGE_1, 2, 1, 0);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(MESSAGE_1, 1, 0, 0);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(MESSAGE_1, 1, 1, 0);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertVotes(MESSAGE_1, 0, 0, 0);
    }

    function testVotesAfterNewSession() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);

        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(MESSAGE_1, 0, 0, 1);
    }

    function testMessageWithThreshold2() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 2, 3);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(MESSAGE_1, 1, 0, 0);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(MESSAGE_1, 0, 0, -1);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(MESSAGE_1, 0, 0, 0);
    }

    function testSameMessageWithThreshold2() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 2, 3);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(MESSAGE_1, 1, 0, 0);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(MESSAGE_1, 0, 0, -1);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(MESSAGE_1, 0, 1, -1);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(MESSAGE_1, 0, 1, 0);

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertVotes(MESSAGE_1, -1, 0, 0);
    }

    function testSameMessageWithThreshold1() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 1, 3);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(MESSAGE_1, 0, -1, -1);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertVotes(MESSAGE_1, 0, -2, -2);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertVotes(MESSAGE_1, 0, -1, -2);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertVotes(MESSAGE_1, 0, 0, -2);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 3);
        assertVotes(MESSAGE_1, -1, 0, -3);
    }

    function testMessageWithThreshold2AndRecovery2() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 2, 2);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 0);
        assertVotes(MESSAGE_1, 1, 0, 0);

        vm.prank(address(adapter2));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(MESSAGE_1, 0, 0, 0); // <- vote from third adapter does not decrease below 0

        vm.prank(address(adapter3));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 1);
        assertVotes(MESSAGE_1, 0, 0, 1);

        vm.prank(address(adapter1));
        multiAdapter.handle(REMOTE_CENT_ID, MESSAGE_1);
        assertEq(gateway.count(REMOTE_CENT_ID), 2);
        assertVotes(MESSAGE_1, 0, -1, 0);
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

        bytes32 payloadId = keccak256(abi.encodePacked(LOCAL_CENT_ID, REMOTE_CENT_ID, keccak256(MESSAGE_1)));

        uint256 cost = GAS_LIMIT * 3 + ADAPTER_ESTIMATE_1 + ADAPTER_ESTIMATE_2 + ADAPTER_ESTIMATE_3;

        _mockAdapter(adapter1, MESSAGE_1, ADAPTER_ESTIMATE_1, ADAPTER_DATA_1);
        _mockAdapter(adapter2, MESSAGE_1, ADAPTER_ESTIMATE_2, ADAPTER_DATA_2);
        _mockAdapter(adapter3, MESSAGE_1, ADAPTER_ESTIMATE_3, ADAPTER_DATA_3);

        vm.expectEmit();
        emit IMultiAdapter.SendPayload(REMOTE_CENT_ID, payloadId, MESSAGE_1, adapter1, ADAPTER_DATA_1, address(REFUND));
        vm.expectEmit();
        emit IMultiAdapter.SendPayload(REMOTE_CENT_ID, payloadId, MESSAGE_1, adapter2, ADAPTER_DATA_2, address(REFUND));
        vm.expectEmit();
        emit IMultiAdapter.SendPayload(REMOTE_CENT_ID, payloadId, MESSAGE_1, adapter3, ADAPTER_DATA_3, address(REFUND));
        multiAdapter.send{value: cost}(REMOTE_CENT_ID, MESSAGE_1, GAS_LIMIT, REFUND);
    }

    function testSendMessageButPoolANotConfigured() public {
        // POOL_A is not configured, and MESSAGE_1 is send from POOL_A, but it works because POOL_0 is the default
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_0, oneAdapter, 1, 1);

        _mockAdapter(adapter1, MESSAGE_1, ADAPTER_ESTIMATE_1, ADAPTER_DATA_1);

        uint256 cost = GAS_LIMIT + ADAPTER_ESTIMATE_1;
        multiAdapter.send{value: cost}(REMOTE_CENT_ID, MESSAGE_1, GAS_LIMIT, REFUND);
    }
}

contract MultiAdapterTestEstimate is MultiAdapterTest {
    function testEstimateNoAdapters() public view {
        assertEq(multiAdapter.estimate(REMOTE_CENT_ID, MESSAGE_1, GAS_LIMIT), 0);
    }

    function testEstimate() public {
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_A, threeAdapters, 3, 3);

        _mockAdapter(adapter1, MESSAGE_1, ADAPTER_ESTIMATE_1, ADAPTER_DATA_1);
        _mockAdapter(adapter2, MESSAGE_1, ADAPTER_ESTIMATE_2, ADAPTER_DATA_2);
        _mockAdapter(adapter3, MESSAGE_1, ADAPTER_ESTIMATE_3, ADAPTER_DATA_3);

        uint256 estimation = GAS_LIMIT * 3 + ADAPTER_ESTIMATE_1 + ADAPTER_ESTIMATE_2 + ADAPTER_ESTIMATE_3;

        assertEq(multiAdapter.estimate(REMOTE_CENT_ID, MESSAGE_1, GAS_LIMIT), estimation);
    }

    function testEstimateButPoolANotConfigured() public {
        // POOL_A is not configured, and MESSAGE_1 is from POOL_A, but it works because POOL_0 is the default
        multiAdapter.setAdapters(REMOTE_CENT_ID, POOL_0, threeAdapters, 3, 3);

        _mockAdapter(adapter1, MESSAGE_1, ADAPTER_ESTIMATE_1, ADAPTER_DATA_1);
        _mockAdapter(adapter2, MESSAGE_1, ADAPTER_ESTIMATE_2, ADAPTER_DATA_2);
        _mockAdapter(adapter3, MESSAGE_1, ADAPTER_ESTIMATE_3, ADAPTER_DATA_3);

        uint256 estimation = GAS_LIMIT * 3 + ADAPTER_ESTIMATE_1 + ADAPTER_ESTIMATE_2 + ADAPTER_ESTIMATE_3;

        assertEq(multiAdapter.estimate(REMOTE_CENT_ID, MESSAGE_1, GAS_LIMIT), estimation);
    }
}
