// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {Mock} from "../../common/mocks/Mock.sol";

import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../../src/common/interfaces/IMessageHandler.sol";

import "forge-std/Test.sol";

import {LayerZeroAdapter} from "../../../src/adapters/LayerZeroAdapter.sol";
import {
    ILayerZeroAdapter,
    IAdapter,
    ILayerZeroReceiver,
    ILayerZeroEndpointV2,
    MessagingParams,
    MessagingFee,
    MessagingReceipt,
    Origin,
    LayerZeroSource,
    LayerZeroDestination
} from "../../../src/adapters/interfaces/ILayerZeroAdapter.sol";

contract MockLayerZeroEndpoint is Mock {
    function send(MessagingParams calldata params, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory)
    {
        values_uint32["params.dstEid"] = params.dstEid;
        values_bytes32["params.receiver"] = params.receiver;
        values_bytes["params.message"] = params.message;
        values_bytes["params.options"] = params.options;
        values_bool["params.payInLzToken"] = params.payInLzToken;

        values_address["refundAddress"] = refundAddress;

        return MessagingReceipt(bytes32(""), 0, MessagingFee(0, 0));
    }

    function setDelegate(address newDelegate) external {
        values_address["delegate"] = newDelegate;
    }

    function quote(MessagingParams calldata, address) external pure returns (MessagingFee memory) {
        return MessagingFee(200_000, 0);
    }
}

contract LayerZeroAdapterTestBase is Test {
    MockLayerZeroEndpoint endpoint;
    LayerZeroAdapter adapter;

    uint16 constant CENTRIFUGE_ID = 1;
    uint32 constant LAYERZERO_ID = 2;
    address immutable DELEGATE = makeAddr("delegate");
    address immutable REMOTE_LAYERZERO_ADDR = makeAddr("remoteAddress");

    IMessageHandler constant GATEWAY = IMessageHandler(address(1));

    function setUp() public {
        endpoint = new MockLayerZeroEndpoint();
        adapter = new LayerZeroAdapter(GATEWAY, address(endpoint), DELEGATE, address(this));
    }

    function testNextNonce() public {
        vm.assertEq(adapter.nextNonce(uint32(0), bytes32("")), 0);
    }
}

contract LayerZeroAdapterTestWire is LayerZeroAdapterTestBase {
    using CastLib for *;

    function testWireErrNotAuthorized() public {
        vm.prank(makeAddr("NotAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        adapter.wire(CENTRIFUGE_ID, LAYERZERO_ID, REMOTE_LAYERZERO_ADDR);
    }

    function testWire() public {
        vm.assertEq(
            adapter.allowInitializePath(Origin(LAYERZERO_ID, REMOTE_LAYERZERO_ADDR.toBytes32LeftPadded(), 0)), false
        );

        vm.expectEmit();
        emit ILayerZeroAdapter.Wire(CENTRIFUGE_ID, LAYERZERO_ID, REMOTE_LAYERZERO_ADDR);
        adapter.wire(CENTRIFUGE_ID, LAYERZERO_ID, REMOTE_LAYERZERO_ADDR);

        vm.assertEq(
            adapter.allowInitializePath(Origin(LAYERZERO_ID, REMOTE_LAYERZERO_ADDR.toBytes32LeftPadded(), 0)), true
        );

        (uint32 layerZeroid, address remoteDestAddress) = adapter.destinations(CENTRIFUGE_ID);
        assertEq(layerZeroid, LAYERZERO_ID);
        assertEq(remoteDestAddress, REMOTE_LAYERZERO_ADDR);

        (uint16 centrifugeId, address remoteSourceAddress) = adapter.sources(LAYERZERO_ID);
        assertEq(centrifugeId, CENTRIFUGE_ID);
        assertEq(remoteSourceAddress, REMOTE_LAYERZERO_ADDR);
    }
}

contract LayerZeroAdapterTestSetDelegate is LayerZeroAdapterTestBase {
    address immutable newDelegate = makeAddr("newDelegate");

    function testSetDelegateErrNotAuthorized() public {
        vm.prank(makeAddr("NotAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        adapter.setDelegate(newDelegate);
    }

    function testSetDelegate() public {
        vm.expectEmit();
        emit ILayerZeroAdapter.SetDelegate(newDelegate);
        adapter.setDelegate(newDelegate);
        assertEq(endpoint.values_address("delegate"), newDelegate);
    }
}

contract LayerZeroAdapterTest is LayerZeroAdapterTestBase {
    using CastLib for *;

    address immutable EXECUTOR = makeAddr("executor");

    function testDeploy() public view {
        assertEq(address(adapter.entrypoint()), address(GATEWAY));
        assertEq(address(adapter.endpoint()), address(endpoint));

        assertEq(endpoint.values_address("delegate"), DELEGATE);

        assertEq(adapter.wards(address(this)), 1);
    }

    function testEstimate(uint64 gasLimit) public view {
        bytes memory payload = "irrelevant";
        assertEq(adapter.estimate(CENTRIFUGE_ID, payload, gasLimit), 200_000);
    }

    function testIncomingCalls(
        bytes memory payload,
        address validAddress,
        address invalidAddress,
        uint16 invalidChain,
        address invalidOrigin
    ) public {
        vm.assume(keccak256(abi.encodePacked(invalidAddress)) != keccak256(abi.encodePacked(validAddress)));
        vm.assume(invalidChain != LAYERZERO_ID);
        vm.assume(invalidOrigin != address(endpoint));
        assumeNotZeroAddress(validAddress);
        assumeNotZeroAddress(invalidAddress);

        vm.mockCall(
            address(GATEWAY), abi.encodeWithSelector(GATEWAY.handle.selector, CENTRIFUGE_ID, payload), abi.encode()
        );

        // Correct input, but not yet setup
        vm.prank(address(endpoint));
        vm.expectRevert(ILayerZeroAdapter.InvalidSource.selector);
        adapter.lzReceive(
            Origin(LAYERZERO_ID, validAddress.toBytes32LeftPadded(), 0), bytes32("1"), payload, EXECUTOR, bytes("")
        );

        adapter.wire(CENTRIFUGE_ID, LAYERZERO_ID, validAddress);

        // Incorrect address
        vm.prank(address(endpoint));
        vm.expectRevert(ILayerZeroAdapter.InvalidSource.selector);
        adapter.lzReceive(
            Origin(LAYERZERO_ID, invalidAddress.toBytes32LeftPadded(), 0), bytes32("1"), payload, EXECUTOR, bytes("")
        );

        // address(0) from invalid chain should fail
        vm.prank(address(endpoint));
        vm.expectRevert(ILayerZeroAdapter.InvalidSource.selector);
        adapter.lzReceive(
            Origin(invalidChain, address(0).toBytes32LeftPadded(), 0), bytes32("1"), payload, EXECUTOR, bytes("")
        );

        // Incorrect sender
        vm.expectRevert(ILayerZeroAdapter.NotLayerZeroEndpoint.selector);
        adapter.lzReceive(
            Origin(LAYERZERO_ID, validAddress.toBytes32LeftPadded(), 0), bytes32("1"), payload, EXECUTOR, bytes("")
        );

        // Correct
        vm.prank(address(endpoint));
        adapter.lzReceive(
            Origin(LAYERZERO_ID, validAddress.toBytes32LeftPadded(), 0), bytes32("1"), payload, EXECUTOR, bytes("")
        );
    }

    function testOutgoingCalls(bytes calldata payload, address invalidOrigin, uint128 gasLimit, address refund)
        public
    {
        vm.assume(invalidOrigin != address(GATEWAY));

        vm.deal(address(this), 0.1 ether);
        vm.expectRevert(IAdapter.NotEntrypoint.selector);
        adapter.send{value: 0.1 ether}(CENTRIFUGE_ID, payload, gasLimit, refund);

        vm.deal(address(GATEWAY), 0.1 ether);
        vm.prank(address(GATEWAY));
        vm.expectRevert(IAdapter.UnknownChainId.selector);
        adapter.send{value: 0.1 ether}(CENTRIFUGE_ID, payload, gasLimit, refund);

        adapter.wire(CENTRIFUGE_ID, LAYERZERO_ID, makeAddr("DestinationAdapter"));

        vm.deal(address(this), 0.1 ether);
        vm.prank(address(GATEWAY));
        adapter.send{value: 0.1 ether}(CENTRIFUGE_ID, payload, gasLimit, refund);

        assertEq(endpoint.values_uint32("params.dstEid"), LAYERZERO_ID);
        assertEq(endpoint.values_bytes32("params.receiver"), makeAddr("DestinationAdapter").toBytes32LeftPadded());
        assertEq(endpoint.values_bytes("params.message"), payload);
        bytes memory expectedOptions = abi.encodePacked(
            uint16(3), // TYPE_3
            uint8(1), // WORKER_ID
            uint16(17), // uint128 gasLimit byte length + 1
            uint8(1), // OPTION_TYPE_LZ
            uint128(gasLimit)
        );
        assertEq(endpoint.values_bytes("params.options"), expectedOptions);
        assertEq(endpoint.values_bool("params.payInLzToken"), false);
        assertEq(endpoint.values_address("refundAddress"), refund);
    }
}
