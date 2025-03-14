// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {Mock} from "test/common/mocks/Mock.sol";

import {WormholeAdapter} from "src/common/WormholeAdapter.sol";
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
        view
        returns (uint256 nativePriceQuote, uint256 targetChainRefundPerGasUnused)
    {
        nativePriceQuote = gasLimit * 2;
        targetChainRefundPerGasUnused = 0;
    }
}

contract WormholeAdapterTest is Test {
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

    // function testEstimate(uint64 gasLimit) public {
    //     bytes memory payload = "irrelevant";
    //     assertEq(adapter.estimate(CENTRIFUGE_CHAIN_ID, payload, gasLimit), gasLimit * 2);
    // }

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

    // function testPayment(bytes calldata payload, uint256 value) public {
    //     vm.deal(address(this), value);
    //     adapter.pay{value: value}(CHAIN_ID, payload, address(this));

    //     uint256[] memory call = axelarGasService.callsWithValue("payNativeGasForContractCall");
    //     assertEq(call.length, 1);
    //     assertEq(call[0], value);
    //     assertEq(axelarGasService.values_address("sender"), address(adapter));
    //     assertEq(axelarGasService.values_string("destinationChain"), adapter.CENTRIFUGE_ID());
    //     assertEq(axelarGasService.values_string("destinationAddress"), adapter.CENTRIFUGE_AXELAR_EXECUTABLE());
    //     assertEq(axelarGasService.values_bytes("payload"), payload);
    //     assertEq(axelarGasService.values_address("refundAddress"), address(this));
    // }

    // function testIncomingCalls(
    //     bytes32 commandId,
    //     string calldata sourceChain,
    //     string calldata sourceAddress,
    //     bytes calldata payload,
    //     address invalidOrigin,
    //     address relayer
    // ) public {
    //     vm.assume(keccak256(abi.encodePacked(sourceChain)) != keccak256(abi.encodePacked("centrifuge")));
    //     vm.assume(invalidOrigin != address(axelarGateway));
    //     vm.assume(
    //         keccak256(abi.encodePacked(sourceAddress)) != keccak256(abi.encodePacked(axelarCentrifugeChainAddress))
    //     );
    //     vm.assume(relayer.code.length == 0);

    //     vm.mockCall(address(GATEWAY), abi.encodeWithSelector(GATEWAY.handle.selector, CHAIN_ID, payload),
    // abi.encode());

    //     vm.prank(address(relayer));
    //     vm.expectRevert(IAxelarAdapter.InvalidChain.selector);
    //     adapter.execute(commandId, sourceChain, axelarCentrifugeChainAddress, payload);

    //     vm.prank(address(relayer));
    //     vm.expectRevert(IAxelarAdapter.InvalidAddress.selector);
    //     adapter.execute(commandId, axelarCentrifugeChainId, sourceAddress, payload);

    //     axelarGateway.setReturn("validateContractCall", false);
    //     vm.prank(address(relayer));
    //     vm.expectRevert(IAxelarAdapter.NotApprovedByAxelarGateway.selector);
    //     adapter.execute(commandId, axelarCentrifugeChainId, axelarCentrifugeChainAddress, payload);

    //     axelarGateway.setReturn("validateContractCall", true);
    //     vm.prank(address(relayer));
    //     adapter.execute(commandId, axelarCentrifugeChainId, axelarCentrifugeChainAddress, payload);
    // }

    function testOutgoingCalls(bytes calldata message, address invalidOrigin) public {
        vm.assume(invalidOrigin != address(GATEWAY));

        vm.expectRevert(IAdapter.NotGateway.selector);
        adapter.send(CENTRIFUGE_CHAIN_ID, message);

        vm.prank(address(GATEWAY));
        vm.expectRevert(IAdapter.UnknownChainId.selector);
        adapter.send(CENTRIFUGE_CHAIN_ID, message);

        adapter.file("target", CENTRIFUGE_CHAIN_ID, WORMHOLE_CHAIN_ID, makeAddr("DestinationAdapter"));

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
