// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {Mock} from "../../core/mocks/Mock.sol";

import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../../src/core/messaging/interfaces/IMessageHandler.sol";

import "forge-std/Test.sol";

import {PolymerAdapter} from "../../../src/adapters/PolymerAdapter.sol";
import {
    IPolymerAdapter,
    IAdapter,
    ICrossL2ProverV2,
    PolymerSource,
    PolymerDestination
} from "../../../src/adapters/interfaces/IPolymerAdapter.sol";

contract MockProver {
    uint32 public returnChainId;
    address public returnEmitter;
    bytes public returnTopics;
    bytes public returnData;

    function setReturn(uint32 chainId_, address emitter_, bytes memory topics_, bytes memory data_) external {
        returnChainId = chainId_;
        returnEmitter = emitter_;
        returnTopics = topics_;
        returnData = data_;
    }

    function validateEvent(bytes calldata)
        external
        view
        returns (uint32 chainId, address emittingContract, bytes memory topics, bytes memory unindexedData)
    {
        return (returnChainId, returnEmitter, returnTopics, returnData);
    }
}

contract PolymerAdapterTestBase is Test {
    MockProver mockProver;
    PolymerAdapter adapter;

    uint16 constant CENTRIFUGE_ID = 1;
    uint32 constant POLYMER_CHAIN_ID = 2;
    address immutable REMOTE_ADAPTER = makeAddr("remoteAdapter");

    IMessageHandler constant GATEWAY = IMessageHandler(address(1));

    function setUp() public {
        mockProver = new MockProver();
        adapter = new PolymerAdapter(GATEWAY, address(mockProver), address(this));
    }
}

contract PolymerAdapterTestWire is PolymerAdapterTestBase {
    function testWireErrNotAuthorized() public {
        vm.prank(makeAddr("NotAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        adapter.wire(CENTRIFUGE_ID, abi.encode(POLYMER_CHAIN_ID, REMOTE_ADAPTER));
    }

    function testWire() public {
        vm.expectEmit();
        emit IPolymerAdapter.Wire(CENTRIFUGE_ID, POLYMER_CHAIN_ID, REMOTE_ADAPTER);
        adapter.wire(CENTRIFUGE_ID, abi.encode(POLYMER_CHAIN_ID, REMOTE_ADAPTER));

        (uint32 polymerChainId, address remoteDestAddress) = adapter.destinations(CENTRIFUGE_ID);
        assertEq(polymerChainId, POLYMER_CHAIN_ID);
        assertEq(remoteDestAddress, REMOTE_ADAPTER);

        (uint16 centrifugeId, address remoteSourceAddress) = adapter.sources(POLYMER_CHAIN_ID);
        assertEq(centrifugeId, CENTRIFUGE_ID);
        assertEq(remoteSourceAddress, REMOTE_ADAPTER);
    }

    function testIsWired() public {
        assertFalse(adapter.isWired(CENTRIFUGE_ID));
        adapter.wire(CENTRIFUGE_ID, abi.encode(POLYMER_CHAIN_ID, REMOTE_ADAPTER));
        assertTrue(adapter.isWired(CENTRIFUGE_ID));
    }
}

contract PolymerAdapterTest is PolymerAdapterTestBase {
    function testDeploy() public view {
        assertEq(address(adapter.entrypoint()), address(GATEWAY));
        assertEq(address(adapter.prover()), address(mockProver));
        assertEq(adapter.wards(address(this)), 1);
        assertEq(adapter.nonce(), 0);
    }

    function testEstimate() public {
        adapter.wire(CENTRIFUGE_ID, abi.encode(POLYMER_CHAIN_ID, REMOTE_ADAPTER));
        assertEq(adapter.estimate(CENTRIFUGE_ID, "irrelevant", 100_000), 0);
    }

    function testEstimateErrUnknownChainId() public {
        vm.expectRevert(IAdapter.UnknownChainId.selector);
        adapter.estimate(CENTRIFUGE_ID, "irrelevant", 100_000);
    }

    function testOutgoingSend() public {
        adapter.wire(CENTRIFUGE_ID, abi.encode(POLYMER_CHAIN_ID, REMOTE_ADAPTER));

        bytes memory payload = "test payload";

        // Not entrypoint
        vm.expectRevert(IAdapter.NotEntrypoint.selector);
        adapter.send(CENTRIFUGE_ID, payload, 0, address(0));

        // Unknown chain
        vm.prank(address(GATEWAY));
        vm.expectRevert(IAdapter.UnknownChainId.selector);
        adapter.send(uint16(99), payload, 0, address(0));

        // Successful send — check event and nonce increment
        vm.expectEmit();
        emit IPolymerAdapter.SendMessage(CENTRIFUGE_ID, REMOTE_ADAPTER, 0, payload);
        vm.prank(address(GATEWAY));
        bytes32 adapterData = adapter.send(CENTRIFUGE_ID, payload, 0, address(0));
        assertEq(adapterData, bytes32(uint256(0)));
        assertEq(adapter.nonce(), 1);

        // Second send increments nonce
        vm.expectEmit();
        emit IPolymerAdapter.SendMessage(CENTRIFUGE_ID, REMOTE_ADAPTER, 1, payload);
        vm.prank(address(GATEWAY));
        adapterData = adapter.send(CENTRIFUGE_ID, payload, 0, address(0));
        assertEq(adapterData, bytes32(uint256(1)));
        assertEq(adapter.nonce(), 2);
    }

    function testIncomingReceiveMessage() public {
        adapter.wire(CENTRIFUGE_ID, abi.encode(POLYMER_CHAIN_ID, REMOTE_ADAPTER));

        bytes memory payload = "test payload";
        uint256 sourceNonce = 42;

        // Encode topics: [eventSelector, centrifugeId (destination), adapter (destination), nonce]
        bytes memory topics = abi.encode(
            adapter.SEND_MESSAGE_SELECTOR(),
            uint16(CENTRIFUGE_ID),
            address(adapter),
            sourceNonce
        );
        bytes memory unindexedData = abi.encode(payload);

        mockProver.setReturn(POLYMER_CHAIN_ID, REMOTE_ADAPTER, topics, unindexedData);

        vm.mockCall(
            address(GATEWAY),
            abi.encodeWithSelector(GATEWAY.handle.selector, CENTRIFUGE_ID, payload),
            abi.encode()
        );

        // Successful receive
        adapter.receiveMessage("proof");
        assertTrue(adapter.processedNonces(POLYMER_CHAIN_ID, sourceNonce));
    }

    function testIncomingReplayProtection() public {
        adapter.wire(CENTRIFUGE_ID, abi.encode(POLYMER_CHAIN_ID, REMOTE_ADAPTER));

        bytes memory payload = "test payload";
        uint256 sourceNonce = 1;

        bytes memory topics =
            abi.encode(adapter.SEND_MESSAGE_SELECTOR(), uint16(CENTRIFUGE_ID), address(adapter), sourceNonce);
        bytes memory unindexedData = abi.encode(payload);

        mockProver.setReturn(POLYMER_CHAIN_ID, REMOTE_ADAPTER, topics, unindexedData);

        vm.mockCall(
            address(GATEWAY),
            abi.encodeWithSelector(GATEWAY.handle.selector, CENTRIFUGE_ID, payload),
            abi.encode()
        );

        // First delivery succeeds
        adapter.receiveMessage("proof");

        // Replay reverts
        vm.expectRevert(IPolymerAdapter.AlreadyProcessed.selector);
        adapter.receiveMessage("proof");
    }

    function testIncomingInvalidTopicsLength() public {
        mockProver.setReturn(POLYMER_CHAIN_ID, REMOTE_ADAPTER, "short", "data");

        vm.expectRevert(IPolymerAdapter.InvalidProof.selector);
        adapter.receiveMessage("proof");
    }

    function testIncomingWrongEventSelector() public {
        bytes memory topics = abi.encode(bytes32("wrong"), uint16(CENTRIFUGE_ID), address(adapter), uint256(0));
        mockProver.setReturn(POLYMER_CHAIN_ID, REMOTE_ADAPTER, topics, abi.encode("payload"));

        vm.expectRevert(IPolymerAdapter.InvalidProof.selector);
        adapter.receiveMessage("proof");
    }

    function testIncomingInvalidSource() public {
        // Not wired — source.addr is address(0)
        bytes memory topics = abi.encode(
            adapter.SEND_MESSAGE_SELECTOR(), uint16(CENTRIFUGE_ID), address(adapter), uint256(0)
        );
        mockProver.setReturn(POLYMER_CHAIN_ID, REMOTE_ADAPTER, topics, abi.encode("payload"));

        vm.expectRevert(IPolymerAdapter.InvalidSource.selector);
        adapter.receiveMessage("proof");
    }

    function testIncomingWrongEmitter() public {
        adapter.wire(CENTRIFUGE_ID, abi.encode(POLYMER_CHAIN_ID, REMOTE_ADAPTER));

        bytes memory topics = abi.encode(
            adapter.SEND_MESSAGE_SELECTOR(), uint16(CENTRIFUGE_ID), address(adapter), uint256(0)
        );
        // Emitting contract doesn't match the wired source adapter
        mockProver.setReturn(POLYMER_CHAIN_ID, makeAddr("wrongEmitter"), topics, abi.encode("payload"));

        vm.expectRevert(IPolymerAdapter.InvalidSource.selector);
        adapter.receiveMessage("proof");
    }

    function testIncomingWrongDestAdapter() public {
        adapter.wire(CENTRIFUGE_ID, abi.encode(POLYMER_CHAIN_ID, REMOTE_ADAPTER));

        // adapter field in event points to wrong address
        bytes memory topics = abi.encode(
            adapter.SEND_MESSAGE_SELECTOR(),
            uint16(CENTRIFUGE_ID),
            makeAddr("wrongAdapter"),
            uint256(0)
        );
        mockProver.setReturn(POLYMER_CHAIN_ID, REMOTE_ADAPTER, topics, abi.encode("payload"));

        vm.expectRevert(IPolymerAdapter.InvalidProof.selector);
        adapter.receiveMessage("proof");
    }
}
