// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {Mock} from "../../core/mocks/Mock.sol";

import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../../src/core/messaging/interfaces/IMessageHandler.sol";

import "forge-std/Test.sol";

import {CCTPAdapter} from "../../../src/adapters/CCTPAdapter.sol";
import {
    ICCTPAdapter,
    IMessageTransmitterV2,
    CCTPSource,
    CCTPDestination
} from "../../../src/adapters/interfaces/ICCTPAdapter.sol";

contract MockMessageTransmitter is Mock {
    function sendMessage(
        uint32 destinationDomain,
        bytes32 recipient,
        bytes32 destinationCaller,
        uint32 minFinalityThreshold,
        bytes calldata messageBody
    ) external {
        values_uint32["destinationDomain"] = destinationDomain;
        values_bytes32["recipient"] = recipient;
        values_bytes32["destinationCaller"] = destinationCaller;
        values_uint32["minFinalityThreshold"] = minFinalityThreshold;
        values_bytes["messageBody"] = messageBody;
    }
}

contract CCTPAdapterTestBase is Test {
    MockMessageTransmitter mockTransmitter;
    CCTPAdapter adapter;

    uint16 constant CENTRIFUGE_ID = 1;
    uint32 constant CCTP_DOMAIN = 2;
    address immutable REMOTE_ADAPTER = makeAddr("remoteAdapter");

    IMessageHandler constant GATEWAY = IMessageHandler(address(1));

    function setUp() public {
        mockTransmitter = new MockMessageTransmitter();
        adapter = new CCTPAdapter(GATEWAY, address(mockTransmitter), address(this));
    }
}

contract CCTPAdapterTestWire is CCTPAdapterTestBase {
    function testWireErrNotAuthorized() public {
        vm.prank(makeAddr("NotAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        adapter.wire(CENTRIFUGE_ID, abi.encode(CCTP_DOMAIN, REMOTE_ADAPTER));
    }

    function testWire() public {
        vm.expectEmit();
        emit ICCTPAdapter.Wire(CENTRIFUGE_ID, CCTP_DOMAIN, REMOTE_ADAPTER);
        adapter.wire(CENTRIFUGE_ID, abi.encode(CCTP_DOMAIN, REMOTE_ADAPTER));

        (uint32 cctpDomain, address remoteDestAddress) = adapter.destinations(CENTRIFUGE_ID);
        assertEq(cctpDomain, CCTP_DOMAIN);
        assertEq(remoteDestAddress, REMOTE_ADAPTER);

        (uint16 centrifugeId, address remoteSourceAddress) = adapter.sources(CCTP_DOMAIN);
        assertEq(centrifugeId, CENTRIFUGE_ID);
        assertEq(remoteSourceAddress, REMOTE_ADAPTER);
    }

    function testIsWired() public {
        assertFalse(adapter.isWired(CENTRIFUGE_ID));
        adapter.wire(CENTRIFUGE_ID, abi.encode(CCTP_DOMAIN, REMOTE_ADAPTER));
        assertTrue(adapter.isWired(CENTRIFUGE_ID));
    }
}

contract CCTPAdapterTest is CCTPAdapterTestBase {
    using CastLib for *;

    function testDeploy() public view {
        assertEq(address(adapter.entrypoint()), address(GATEWAY));
        assertEq(address(adapter.messageTransmitter()), address(mockTransmitter));
        assertEq(adapter.MIN_FINALITY_THRESHOLD(), 1000);
        assertEq(adapter.wards(address(this)), 1);
    }

    function testEstimate() public {
        adapter.wire(CENTRIFUGE_ID, abi.encode(CCTP_DOMAIN, REMOTE_ADAPTER));
        assertEq(adapter.estimate(CENTRIFUGE_ID, "irrelevant", 100_000), 0);
    }

    function testEstimateErrUnknownChainId() public {
        vm.expectRevert(IAdapter.UnknownChainId.selector);
        adapter.estimate(CENTRIFUGE_ID, "irrelevant", 100_000);
    }

    function testOutgoingSend(bytes calldata payload, uint128 gasLimit, address refund) public {
        adapter.wire(CENTRIFUGE_ID, abi.encode(CCTP_DOMAIN, REMOTE_ADAPTER));

        // Not entrypoint
        vm.expectRevert(IAdapter.NotEntrypoint.selector);
        adapter.send(CENTRIFUGE_ID, payload, gasLimit, refund);

        // Unknown chain
        vm.prank(address(GATEWAY));
        vm.expectRevert(IAdapter.UnknownChainId.selector);
        adapter.send(uint16(99), payload, gasLimit, refund);

        // Successful send
        vm.prank(address(GATEWAY));
        bytes32 adapterData = adapter.send(CENTRIFUGE_ID, payload, gasLimit, refund);
        assertEq(adapterData, bytes32(0));

        assertEq(mockTransmitter.values_uint32("destinationDomain"), CCTP_DOMAIN);
        assertEq(mockTransmitter.values_bytes32("recipient"), REMOTE_ADAPTER.toBytes32LeftPadded());
        assertEq(mockTransmitter.values_bytes32("destinationCaller"), bytes32(0));
        assertEq(mockTransmitter.values_uint32("minFinalityThreshold"), 1000);
        assertEq(mockTransmitter.values_bytes("messageBody"), payload);
    }

    function testIncomingHandleReceiveFinalizedMessage(bytes calldata payload) public {
        adapter.wire(CENTRIFUGE_ID, abi.encode(CCTP_DOMAIN, REMOTE_ADAPTER));

        vm.mockCall(
            address(GATEWAY), abi.encodeWithSelector(GATEWAY.handle.selector, CENTRIFUGE_ID, payload), abi.encode()
        );

        vm.prank(address(mockTransmitter));
        bool ok =
            adapter.handleReceiveFinalizedMessage(CCTP_DOMAIN, REMOTE_ADAPTER.toBytes32LeftPadded(), 1000, payload);
        assertTrue(ok);
    }

    function testIncomingNotMessageTransmitter(address invalidCaller) public {
        vm.assume(invalidCaller != address(mockTransmitter));
        adapter.wire(CENTRIFUGE_ID, abi.encode(CCTP_DOMAIN, REMOTE_ADAPTER));

        vm.prank(invalidCaller);
        vm.expectRevert(ICCTPAdapter.NotMessageTransmitter.selector);
        adapter.handleReceiveFinalizedMessage(CCTP_DOMAIN, REMOTE_ADAPTER.toBytes32LeftPadded(), 1000, "payload");
    }

    function testIncomingUnknownSourceDomain(uint32 unknownDomain) public {
        vm.assume(unknownDomain != CCTP_DOMAIN);
        adapter.wire(CENTRIFUGE_ID, abi.encode(CCTP_DOMAIN, REMOTE_ADAPTER));

        vm.prank(address(mockTransmitter));
        vm.expectRevert(ICCTPAdapter.InvalidSource.selector);
        adapter.handleReceiveFinalizedMessage(unknownDomain, REMOTE_ADAPTER.toBytes32LeftPadded(), 1000, "payload");
    }

    function testIncomingWrongSender(address wrongSender) public {
        vm.assume(wrongSender != REMOTE_ADAPTER);
        adapter.wire(CENTRIFUGE_ID, abi.encode(CCTP_DOMAIN, REMOTE_ADAPTER));

        vm.prank(address(mockTransmitter));
        vm.expectRevert(ICCTPAdapter.InvalidSource.selector);
        adapter.handleReceiveFinalizedMessage(CCTP_DOMAIN, wrongSender.toBytes32LeftPadded(), 1000, "payload");
    }

    function testIncomingUnfinalizedRejected() public {
        adapter.wire(CENTRIFUGE_ID, abi.encode(CCTP_DOMAIN, REMOTE_ADAPTER));

        vm.prank(address(mockTransmitter));
        vm.expectRevert(ICCTPAdapter.UnfinalizedNotSupported.selector);
        adapter.handleReceiveUnfinalizedMessage(CCTP_DOMAIN, REMOTE_ADAPTER.toBytes32LeftPadded(), 500, "payload");
    }

    function testIncomingUnfinalizedNotMessageTransmitter(address invalidCaller) public {
        vm.assume(invalidCaller != address(mockTransmitter));

        vm.prank(invalidCaller);
        vm.expectRevert(ICCTPAdapter.NotMessageTransmitter.selector);
        adapter.handleReceiveUnfinalizedMessage(CCTP_DOMAIN, REMOTE_ADAPTER.toBytes32LeftPadded(), 500, "payload");
    }
}
