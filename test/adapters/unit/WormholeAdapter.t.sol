// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {Mock} from "../../core/mocks/Mock.sol";

import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../../src/core/messaging/interfaces/IMessageHandler.sol";

import "forge-std/Test.sol";

import {WormholeAdapter} from "../../../src/adapters/WormholeAdapter.sol";
import {IWormholeAdapter} from "../../../src/adapters/interfaces/IWormholeAdapter.sol";

contract MockWormholeDeliveryProvider {
    uint16 public immutable chainId = 2;
}

contract MockWormholeRelayer is Mock {
    address public getDefaultDeliveryProvider = address(new MockWormholeDeliveryProvider());

    function sendPayloadToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256 receiverValue,
        uint256 gasLimit,
        uint16 refundChain,
        address refundAddress
    ) external payable returns (uint64 sequence) {
        values_uint256["value"] = msg.value;
        values_uint16["targetChain"] = targetChain;
        values_address["targetAddress"] = targetAddress;
        values_bytes["payload"] = payload;
        values_uint256["receiverValue"] = receiverValue;
        values_uint256["gasLimit"] = gasLimit;
        values_uint16["refundChain"] = refundChain;
        values_address["refundAddress"] = refundAddress;

        return 0;
    }

    function quoteEVMDeliveryPrice(uint16, uint256, uint256 gasLimit)
        external
        pure
        returns (uint256 nativePriceQuote, uint256 targetChainRefundPerGasUnused)
    {
        nativePriceQuote = gasLimit * 2;
        targetChainRefundPerGasUnused = 0;
    }
}

contract WormholeAdapterTestBase is Test {
    MockWormholeRelayer relayer;
    WormholeAdapter adapter;

    uint16 constant CENTRIFUGE_CHAIN_ID = 1;
    uint16 constant WORMHOLE_CHAIN_ID = 2;
    address immutable REMOTE_WORMHOLE_ADDR = makeAddr("remoteAddress");
    uint8 constant GAS_MULTIPLIER = 10; // 10%

    IMessageHandler constant GATEWAY = IMessageHandler(address(1));

    function setUp() public {
        relayer = new MockWormholeRelayer();
        adapter = new WormholeAdapter(GATEWAY, address(relayer), address(this));
    }
}

contract WormholeAdapterTestWire is WormholeAdapterTestBase {
    function testWireErrNotAuthorized() public {
        vm.prank(makeAddr("NotAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        adapter.wire(CENTRIFUGE_CHAIN_ID, GAS_MULTIPLIER, abi.encode(WORMHOLE_CHAIN_ID, REMOTE_WORMHOLE_ADDR));
    }

    function testWire() public {
        adapter.wire(CENTRIFUGE_CHAIN_ID, GAS_MULTIPLIER, abi.encode(WORMHOLE_CHAIN_ID, REMOTE_WORMHOLE_ADDR));

        (uint16 wormholeId, uint8 gasBufferPercentage, address remoteDestAddress) =
            adapter.destinations(CENTRIFUGE_CHAIN_ID);
        assertEq(wormholeId, WORMHOLE_CHAIN_ID);
        assertEq(remoteDestAddress, REMOTE_WORMHOLE_ADDR);
        assertEq(gasBufferPercentage, GAS_MULTIPLIER);

        (uint16 centrifugeId, address remoteSourceAddress) = adapter.sources(WORMHOLE_CHAIN_ID);
        assertEq(centrifugeId, CENTRIFUGE_CHAIN_ID);
        assertEq(remoteSourceAddress, REMOTE_WORMHOLE_ADDR);
    }

    function testIsWired() public {
        assertFalse(adapter.isWired(CENTRIFUGE_CHAIN_ID));
        adapter.wire(CENTRIFUGE_CHAIN_ID, GAS_MULTIPLIER, abi.encode(WORMHOLE_CHAIN_ID, REMOTE_WORMHOLE_ADDR));
        assertTrue(adapter.isWired(CENTRIFUGE_CHAIN_ID));
    }
}

contract WormholeAdapterTest is WormholeAdapterTestBase {
    using CastLib for *;

    function testDeploy() public view {
        assertEq(address(adapter.entrypoint()), address(GATEWAY));
        assertEq(address(adapter.relayer()), address(relayer));
        assertEq(adapter.localWormholeId(), 2);

        assertEq(adapter.wards(address(this)), 1);
    }

    function testEstimate(uint64 gasLimit) public {
        adapter.wire(CENTRIFUGE_CHAIN_ID, GAS_MULTIPLIER, abi.encode(WORMHOLE_CHAIN_ID, REMOTE_WORMHOLE_ADDR));

        bytes memory payload = "irrelevant";
        assertEq(
            adapter.estimate(CENTRIFUGE_CHAIN_ID, payload, gasLimit),
            uint128(gasLimit + adapter.RECEIVE_COST()) * 2 * GAS_MULTIPLIER
        );
    }

    function testIncomingCalls(
        bytes memory payload,
        address validAddress,
        address invalidAddress,
        uint16 invalidChain,
        address invalidOrigin
    ) public {
        vm.assume(keccak256(abi.encodePacked(invalidAddress)) != keccak256(abi.encodePacked(validAddress)));
        vm.assume(invalidChain != WORMHOLE_CHAIN_ID);
        vm.assume(invalidOrigin != address(relayer));
        assumeNotZeroAddress(validAddress);
        assumeNotZeroAddress(invalidAddress);

        bytes[] memory vaas;

        vm.mockCall(
            address(GATEWAY),
            abi.encodeWithSelector(GATEWAY.handle.selector, CENTRIFUGE_CHAIN_ID, payload),
            abi.encode()
        );

        // Correct input, but not yet setup
        vm.prank(address(relayer));
        vm.expectRevert(IWormholeAdapter.InvalidSource.selector);
        adapter.receiveWormholeMessages(
            payload, vaas, validAddress.toBytes32LeftPadded(), WORMHOLE_CHAIN_ID, bytes32(0)
        );

        adapter.wire(CENTRIFUGE_CHAIN_ID, GAS_MULTIPLIER, abi.encode(WORMHOLE_CHAIN_ID, validAddress));

        // Incorrect address
        vm.prank(address(relayer));
        vm.expectRevert(IWormholeAdapter.InvalidSource.selector);
        adapter.receiveWormholeMessages(
            payload, vaas, invalidAddress.toBytes32LeftPadded(), WORMHOLE_CHAIN_ID, bytes32(0)
        );

        // address(0) from invalid chain should fail
        vm.prank(address(relayer));
        vm.expectRevert(IWormholeAdapter.InvalidSource.selector);
        adapter.receiveWormholeMessages(payload, vaas, address(0).toBytes32LeftPadded(), invalidChain, bytes32(0));

        // Incorrect sender
        vm.expectRevert(IWormholeAdapter.NotWormholeRelayer.selector);
        adapter.receiveWormholeMessages(
            payload, vaas, validAddress.toBytes32LeftPadded(), WORMHOLE_CHAIN_ID, bytes32(0)
        );

        // Correct
        vm.prank(address(relayer));
        adapter.receiveWormholeMessages(
            payload, vaas, validAddress.toBytes32LeftPadded(), WORMHOLE_CHAIN_ID, bytes32(0)
        );
    }

    function testOutgoingCalls(bytes calldata payload, address invalidOrigin, uint256 gasLimit, address refund)
        public
    {
        gasLimit = uint256(bound(gasLimit, 0, adapter.RECEIVE_COST() - 1));
        vm.assume(invalidOrigin != address(GATEWAY));

        vm.deal(address(this), 0.1 ether);
        vm.expectRevert(IAdapter.NotEntrypoint.selector);
        adapter.send{value: 0.1 ether}(CENTRIFUGE_CHAIN_ID, payload, gasLimit, refund);

        vm.deal(address(GATEWAY), 0.1 ether);
        vm.prank(address(GATEWAY));
        vm.expectRevert(IAdapter.UnknownChainId.selector);
        adapter.send{value: 0.1 ether}(CENTRIFUGE_CHAIN_ID, payload, gasLimit, refund);

        adapter.wire(CENTRIFUGE_CHAIN_ID, GAS_MULTIPLIER, abi.encode(WORMHOLE_CHAIN_ID, makeAddr("DestinationAdapter")));

        vm.deal(address(this), 0.1 ether);
        vm.prank(address(GATEWAY));
        adapter.send{value: 0.1 ether}(CENTRIFUGE_CHAIN_ID, payload, gasLimit, refund);

        assertEq(relayer.values_uint256("value"), 0.1 ether);
        assertEq(relayer.values_uint16("targetChain"), WORMHOLE_CHAIN_ID);
        assertEq(relayer.values_address("targetAddress"), makeAddr("DestinationAdapter"));
        assertEq(relayer.values_bytes("payload"), payload);
        assertEq(relayer.values_uint256("receiverValue"), 0);
        assertEq(relayer.values_uint256("gasLimit"), (gasLimit + adapter.RECEIVE_COST()) * GAS_MULTIPLIER);
        assertEq(relayer.values_uint16("refundChain"), WORMHOLE_CHAIN_ID);
        assertEq(relayer.values_address("refundAddress"), refund);
    }
}
