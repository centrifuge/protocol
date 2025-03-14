// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {Mock} from "test/common/mocks/Mock.sol";

import {AxelarAdapter, IAdapter, IAxelarAdapter} from "src/common/AxelarAdapter.sol";
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
    MockAxelarGateway axelarGateway;
    MockAxelarGasService axelarGasService;
    AxelarAdapter adapter;

    uint32 constant CHAIN_ID = 1;
    string private constant axelarCentrifugeChainId = "centrifuge";
    string private constant axelarCentrifugeChainAddress = "0x7369626CEF070000000000000000000000000000";
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
        uint256 axelarCost = 10;
        vm.assume(gasLimit < type(uint256).max - axelarCost);

        adapter.file("axelarCost", axelarCost);

        bytes memory payload = "irrelevant";

        uint256 estimation = adapter.estimate(CHAIN_ID, payload, gasLimit);
        assertEq(estimation, gasLimit + axelarCost);
    }

    function testFiling(uint256 value) public {
        vm.assume(value != adapter.axelarCost());

        adapter.file("axelarCost", value);
        assertEq(adapter.axelarCost(), value);

        vm.expectRevert(IAxelarAdapter.FileUnrecognizedParam.selector);
        adapter.file("random", value);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        adapter.file("axelarCost", value);
    }

    function testPayment(bytes calldata payload, uint256 value) public {
        vm.deal(address(this), value);
        adapter.pay{value: value}(CHAIN_ID, payload, address(this));

        uint256[] memory call = axelarGasService.callsWithValue("payNativeGasForContractCall");
        assertEq(call.length, 1);
        assertEq(call[0], value);
        assertEq(axelarGasService.values_address("sender"), address(adapter));
        assertEq(axelarGasService.values_string("destinationChain"), adapter.CENTRIFUGE_ID());
        assertEq(axelarGasService.values_string("destinationAddress"), adapter.CENTRIFUGE_AXELAR_EXECUTABLE());
        assertEq(axelarGasService.values_bytes("payload"), payload);
        assertEq(axelarGasService.values_address("refundAddress"), address(this));
    }

    function testIncomingCalls(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload,
        address invalidOrigin,
        address relayer
    ) public {
        vm.assume(keccak256(abi.encodePacked(sourceChain)) != keccak256(abi.encodePacked("centrifuge")));
        vm.assume(invalidOrigin != address(axelarGateway));
        vm.assume(
            keccak256(abi.encodePacked(sourceAddress)) != keccak256(abi.encodePacked(axelarCentrifugeChainAddress))
        );
        vm.assume(relayer.code.length == 0);

        vm.mockCall(address(GATEWAY), abi.encodeWithSelector(GATEWAY.handle.selector, CHAIN_ID, payload), abi.encode());

        vm.prank(address(relayer));
        vm.expectRevert(IAxelarAdapter.InvalidChain.selector);
        adapter.execute(commandId, sourceChain, axelarCentrifugeChainAddress, payload);

        vm.prank(address(relayer));
        vm.expectRevert(IAxelarAdapter.InvalidAddress.selector);
        adapter.execute(commandId, axelarCentrifugeChainId, sourceAddress, payload);

        axelarGateway.setReturn("validateContractCall", false);
        vm.prank(address(relayer));
        vm.expectRevert(IAxelarAdapter.NotApprovedByAxelarGateway.selector);
        adapter.execute(commandId, axelarCentrifugeChainId, axelarCentrifugeChainAddress, payload);

        axelarGateway.setReturn("validateContractCall", true);
        vm.prank(address(relayer));
        adapter.execute(commandId, axelarCentrifugeChainId, axelarCentrifugeChainAddress, payload);
    }

    function testOutgoingCalls(bytes calldata message, address invalidOrigin) public {
        vm.assume(invalidOrigin != address(GATEWAY));

        vm.expectRevert(IAdapter.NotGateway.selector);
        adapter.send(CHAIN_ID, message);

        vm.prank(address(GATEWAY));
        adapter.send(CHAIN_ID, message);

        assertEq(axelarGateway.values_string("destinationChain"), axelarCentrifugeChainId);
        assertEq(axelarGateway.values_string("contractAddress"), adapter.CENTRIFUGE_AXELAR_EXECUTABLE());
        assertEq(axelarGateway.values_bytes("payload"), message);
    }
}
