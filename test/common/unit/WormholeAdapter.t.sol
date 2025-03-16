// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {Mock} from "test/common/mocks/Mock.sol";

import {WormholeAdapter} from "src/common/WormholeAdapter.sol";
import {IWormholeAdapter} from "src/common/interfaces/IWormholeAdapter.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";

contract MockWormholeRelayer is Mock {
    function sendPayloadToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256 receiverValue,
        uint256 gasLimit,
        uint16 refundChain,
        address refundAddress
    ) external payable returns (uint64 sequence) {
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

contract WormholeAdapterTest is Test {
    using CastLib for *;

    MockWormholeRelayer relayer;
    WormholeAdapter adapter;

    uint32 constant CENTRIFUGE_CHAIN_ID = 1;
    uint16 constant WORMHOLE_CHAIN_ID = 2;
    IMessageHandler constant GATEWAY = IMessageHandler(address(1));

    function setUp() public {
        relayer = new MockWormholeRelayer();
        adapter = new WormholeAdapter(GATEWAY, address(relayer), WORMHOLE_CHAIN_ID);
    }

    function testDeploy() public view {
        assertEq(address(adapter.gateway()), address(GATEWAY));
        assertEq(address(adapter.relayer()), address(relayer));
        assertEq(adapter.refundChain(), 2);

        assertEq(adapter.wards(address(this)), 1);
    }

    function testEstimate(uint64 gasLimit) public pure {
        bytes memory payload = "irrelevant";
        assertEq(adapter.estimate(CENTRIFUGE_CHAIN_ID, payload, gasLimit), uint128(gasLimit) * 2);
    }

    // function testFiling(uint256 value) public {
    //     vm.assume(value != adapter.axelarCost());

    //     adapter.file("axelarCost", value);
    //     assertEq(adapter.axelarCost(), value);

    //     vm.expectRevert(IAxelarAdapter.FileUnrecognizedParam.selector);
    //     adapter.file("random", value);

    //     vm.prank(makeAddr("unauthorized"));
    //     vm.expectRevert(IAuth.NotAuthorized.selector);
    //     adapter.file("axelarCost", value);
    // }

    function testPayment(bytes calldata payload) public {
        vm.deal(address(this), 0.3 ether);

        assertEq(adapter.gasPaid(), 0 ether);
        assertEq(adapter.refund(), address(0));

        adapter.pay{value: 0.1 ether}(CENTRIFUGE_CHAIN_ID, payload, address(this));

        assertEq(adapter.gasPaid(), 0.1 ether);
        assertEq(adapter.refund(), address(this));

        adapter.pay{value: 0.2 ether}(CENTRIFUGE_CHAIN_ID, payload, address(this));

        assertEq(adapter.gasPaid(), 0.3 ether);
        assertEq(adapter.refund(), address(this));
    }

    function testIncomingCallsWormhole(
        bytes memory payload,
        address validAddress,
        address invalidAddress,
        uint16 invalidChain,
        address invalidOrigin
    ) public {
        vm.assume(keccak256(abi.encodePacked(invalidAddress)) != keccak256(abi.encodePacked(validAddress)));
        vm.assume(invalidChain != WORMHOLE_CHAIN_ID);
        vm.assume(invalidOrigin != address(relayer));

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

        adapter.file("sources", WORMHOLE_CHAIN_ID, CENTRIFUGE_CHAIN_ID, validAddress);

        // Incorrect address
        vm.prank(address(relayer));
        vm.expectRevert(IWormholeAdapter.InvalidSource.selector);
        adapter.receiveWormholeMessages(
            payload, vaas, invalidAddress.toBytes32LeftPadded(), WORMHOLE_CHAIN_ID, bytes32(0)
        );

        // Incorrect chain
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

    function testOutgoingCalls(bytes calldata message, address invalidOrigin) public {
        vm.assume(invalidOrigin != address(GATEWAY));

        vm.expectRevert(IAdapter.NotGateway.selector);
        adapter.send(CENTRIFUGE_CHAIN_ID, message);

        vm.prank(address(GATEWAY));
        vm.expectRevert(IAdapter.UnknownChainId.selector);
        adapter.send(CENTRIFUGE_CHAIN_ID, message);

        adapter.file("destinations", CENTRIFUGE_CHAIN_ID, WORMHOLE_CHAIN_ID, makeAddr("DestinationAdapter"));

        vm.prank(address(GATEWAY));
        adapter.send(CENTRIFUGE_CHAIN_ID, message);

        assertEq(relayer.values_uint16("targetChain"), WORMHOLE_CHAIN_ID);
        assertEq(relayer.values_address("targetAddress"), makeAddr("DestinationAdapter"));
        assertEq(relayer.values_bytes("payload"), message);
        assertEq(relayer.values_uint256("receiverValue"), 0);
        assertEq(relayer.values_uint256("gasLimit"), 1); // TODO
        assertEq(relayer.values_uint16("refundChain"), 2);
        assertEq(relayer.values_address("refundAddress"), address(GATEWAY));
    }
}
