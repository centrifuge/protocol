// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {Mock} from "test/common/mocks/Mock.sol";

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {AxelarAdapter, IAdapter, IAxelarAdapter, IAxelarExecutable} from "src/common/AxelarAdapter.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";

contract MockAxelarGateway is Mock {
    function validateContractCall(bytes32, string calldata, string calldata, bytes32) public view returns (bool) {
        return values_bool_return["validateContractCall"];
    }

    function callContract(string calldata destinationChain, string calldata contractAddress, bytes calldata payload)
        public
    {
        values_string["destinationChain"] = destinationChain;
        values_string["contractAddress"] = contractAddress;
        values_bytes["payload"] = payload;
    }
}

contract MockAxelarGasService is Mock {
    function estimateGasFee(string calldata, string calldata, bytes calldata, uint256, bytes calldata /* params */ )
        external
        view
        returns (uint256 gasEstimate)
    {
        return values_uint256_return["estimateGasFee"];
    }

    function payNativeGasForContractCall(
        address sender,
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        address refundAddress
    ) external payable {
        callWithValue("payNativeGasForContractCall", msg.value);
        values_address["sender"] = sender;
        values_string["destinationChain"] = destinationChain;
        values_string["destinationAddress"] = destinationAddress;
        values_bytes["payload"] = payload;
        values_address["refundAddress"] = refundAddress;
    }
}

contract AxelarAdapterTest is Test {
    using CastLib for *;

    uint32 constant CENTRIFUGE_CHAIN_ID = 1;
    string constant AXELAR_CHAIN_ID = "mainnet";

    MockAxelarGateway axelarGateway;
    MockAxelarGasService axelarGasService;
    AxelarAdapter adapter;

    IMessageHandler constant GATEWAY = IMessageHandler(address(1));

    function setUp() public {
        axelarGateway = new MockAxelarGateway();
        axelarGasService = new MockAxelarGasService();
        adapter = new AxelarAdapter(GATEWAY, address(axelarGateway), address(axelarGasService));
    }

    function testDeploy() public view {
        assertEq(address(adapter.gateway()), address(GATEWAY));
        assertEq(address(adapter.axelarGateway()), address(axelarGateway));
        assertEq(address(adapter.axelarGasService()), address(axelarGasService));

        assertEq(adapter.wards(address(this)), 1);
    }

    function testEstimate(uint256 gasLimit) public {
        vm.assume(gasLimit > 0);

        bytes memory payload = "irrelevant";

        axelarGasService.setReturn("estimateGasFee", gasLimit - 1);

        uint256 estimation = adapter.estimate(CENTRIFUGE_CHAIN_ID, payload, gasLimit);
        assertEq(estimation, gasLimit - 1);
    }

    function testIncomingCalls(
        bytes32 commandId,
        address validAddress,
        address invalidAddress,
        string calldata invalidChain,
        bytes calldata payload,
        address invalidOrigin,
        address relayer
    ) public {
        vm.assume(keccak256(abi.encodePacked(invalidAddress)) != keccak256(abi.encodePacked(validAddress)));
        vm.assume(keccak256(abi.encodePacked(invalidChain)) != keccak256(abi.encodePacked(AXELAR_CHAIN_ID)));
        vm.assume(invalidOrigin != address(axelarGateway));
        vm.assume(relayer.code.length == 0);
        assumeNotZeroAddress(validAddress);
        assumeNotZeroAddress(invalidAddress);

        vm.mockCall(
            address(GATEWAY),
            abi.encodeWithSelector(GATEWAY.handle.selector, CENTRIFUGE_CHAIN_ID, payload),
            abi.encode()
        );

        // Correct input, but not yet setup
        axelarGateway.setReturn("validateContractCall", true);
        vm.expectRevert(IAxelarExecutable.InvalidAddress.selector);
        vm.prank(address(relayer));
        adapter.execute(commandId, AXELAR_CHAIN_ID, validAddress.toString(), payload);

        adapter.file("sources", AXELAR_CHAIN_ID, CENTRIFUGE_CHAIN_ID, validAddress);

        // Incorrect address
        vm.prank(address(relayer));
        vm.expectRevert(IAxelarExecutable.InvalidAddress.selector);
        adapter.execute(commandId, AXELAR_CHAIN_ID, invalidAddress.toString(), payload);

        // Incorrect chain
        vm.prank(address(relayer));
        vm.expectRevert(IAxelarExecutable.InvalidAddress.selector);
        adapter.execute(commandId, invalidChain, validAddress.toString(), payload);

        // Axelar has not approved the payload
        axelarGateway.setReturn("validateContractCall", false);
        vm.prank(address(relayer));
        vm.expectRevert(IAxelarExecutable.NotApprovedByGateway.selector);
        adapter.execute(commandId, AXELAR_CHAIN_ID, validAddress.toString(), payload);

        // Correct
        axelarGateway.setReturn("validateContractCall", true);
        vm.prank(address(relayer));
        adapter.execute(commandId, AXELAR_CHAIN_ID, validAddress.toString(), payload);
    }

    function testOutgoingCalls(bytes calldata payload, address invalidOrigin, uint256 gasLimit, address refund)
        public
    {
        vm.assume(invalidOrigin != address(GATEWAY));

        vm.deal(address(this), 0.1 ether);
        vm.expectRevert(IAdapter.NotGateway.selector);
        adapter.send{value: 0.1 ether}(CENTRIFUGE_CHAIN_ID, payload, gasLimit, refund);

        vm.deal(address(GATEWAY), 0.1 ether);
        vm.prank(address(GATEWAY));
        vm.expectRevert(IAdapter.UnknownChainId.selector);
        adapter.send{value: 0.1 ether}(CENTRIFUGE_CHAIN_ID, payload, gasLimit, refund);

        adapter.file("destinations", CENTRIFUGE_CHAIN_ID, AXELAR_CHAIN_ID, makeAddr("DestinationAdapter"));

        vm.deal(address(this), 0.1 ether);
        vm.prank(address(GATEWAY));
        adapter.send{value: 0.1 ether}(CENTRIFUGE_CHAIN_ID, payload, gasLimit, refund);

        uint256[] memory call = axelarGasService.callsWithValue("payNativeGasForContractCall");
        assertEq(call.length, 1);
        assertEq(call[0], 0.1 ether);
        assertEq(axelarGasService.values_address("sender"), address(adapter));
        assertEq(axelarGasService.values_string("destinationChain"), AXELAR_CHAIN_ID);
        assertEq(axelarGasService.values_string("destinationAddress"), makeAddr("DestinationAdapter").toString());
        assertEq(axelarGasService.values_bytes("payload"), payload);
        assertEq(axelarGasService.values_address("refundAddress"), refund);

        assertEq(axelarGateway.values_string("destinationChain"), AXELAR_CHAIN_ID);
        assertEq(axelarGateway.values_string("contractAddress"), makeAddr("DestinationAdapter").toString());
        assertEq(axelarGateway.values_bytes("payload"), payload);
    }
}
