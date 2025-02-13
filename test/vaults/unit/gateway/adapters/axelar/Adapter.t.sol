// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AxelarAdapter} from "src/vaults/gateway/adapters/axelar/Adapter.sol";
import {MockAxelarGateway} from "test/vaults/mocks/MockAxelarGateway.sol";
import {MockGateway} from "test/vaults/mocks/MockGateway.sol";
import {MockAxelarGasService} from "test/vaults/mocks/MockAxelarGasService.sol";
import {AxelarForwarder} from "src/vaults/gateway/adapters/axelar/Forwarder.sol";
import {BytesLib} from "src/vaults/libraries/BytesLib.sol";

contract AxelarAdapterTest is Test {
    MockAxelarGateway axelarGateway;
    MockGateway gateway;
    MockAxelarGasService axelarGasService;
    AxelarAdapter adapter;

    string private constant axelarCentrifugeChainId = "centrifuge";
    string private constant axelarCentrifugeChainAddress = "0x7369626CEF070000000000000000000000000000";

    function setUp() public {
        axelarGateway = new MockAxelarGateway();
        gateway = new MockGateway();
        axelarGasService = new MockAxelarGasService();
        adapter = new AxelarAdapter(address(gateway), address(axelarGateway), address(axelarGasService));
    }

    function testDeploy() public {
        adapter = new AxelarAdapter(address(gateway), address(axelarGateway), address(axelarGasService));
        assertEq(address(adapter.gateway()), address(gateway));
        assertEq(address(adapter.axelarGateway()), address(axelarGateway));
        assertEq(address(adapter.axelarGasService()), address(axelarGasService));

        assertEq(adapter.wards(address(this)), 1);
    }

    function testEstimate(uint256 gasLimit) public {
        uint256 axelarCost = 10;
        vm.assume(gasLimit < type(uint256).max - axelarCost);

        adapter.file("axelarCost", axelarCost);

        bytes memory payload = "irrelevant";

        uint256 estimation = adapter.estimate(payload, gasLimit);
        assertEq(estimation, gasLimit + axelarCost);
    }

    function testFiling(uint256 value) public {
        vm.assume(value != adapter.axelarCost());

        adapter.file("axelarCost", value);
        assertEq(adapter.axelarCost(), value);

        vm.expectRevert(bytes("AxelarAdapterfile-unrecognized-param"));
        adapter.file("random", value);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert("Auth/not-authorized");
        adapter.file("axelarCost", value);
    }

    function testPayment(bytes calldata payload, uint256 value) public {
        vm.deal(address(this), value);
        adapter.pay{value: value}(payload, address(this));

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

        vm.prank(address(relayer));
        vm.expectRevert(bytes("AxelarAdapter/invalid-chain"));
        adapter.execute(commandId, sourceChain, axelarCentrifugeChainAddress, payload);

        vm.prank(address(relayer));
        vm.expectRevert(bytes("AxelarAdapter/invalid-address"));
        adapter.execute(commandId, axelarCentrifugeChainId, sourceAddress, payload);

        axelarGateway.setReturn("validateContractCall", false);
        vm.prank(address(relayer));
        vm.expectRevert(bytes("AxelarAdapter/not-approved-by-axelar-gateway"));
        adapter.execute(commandId, axelarCentrifugeChainId, axelarCentrifugeChainAddress, payload);

        axelarGateway.setReturn("validateContractCall", true);
        vm.prank(address(relayer));
        adapter.execute(commandId, axelarCentrifugeChainId, axelarCentrifugeChainAddress, payload);
    }

    function testOutgoingCalls(bytes calldata message, address invalidOrigin) public {
        vm.assume(invalidOrigin != address(gateway));

        vm.expectRevert(bytes("AxelarAdapter/not-gateway"));
        adapter.send(message);

        vm.prank(address(gateway));
        adapter.send(message);

        assertEq(axelarGateway.values_string("destinationChain"), axelarCentrifugeChainId);
        assertEq(axelarGateway.values_string("contractAddress"), adapter.CENTRIFUGE_AXELAR_EXECUTABLE());
        assertEq(axelarGateway.values_bytes("payload"), message);
    }
}
