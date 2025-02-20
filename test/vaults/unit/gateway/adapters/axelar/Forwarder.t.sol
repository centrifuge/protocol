// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {MockAxelarPrecompile} from "test/vaults/mocks/MockAxelarPrecompile.sol";
import {MockAxelarGateway} from "test/vaults/mocks/MockAxelarGateway.sol";
import {AxelarForwarder} from "src/vaults/gateway/adapters/axelar/Forwarder.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

contract AxelarForwarderTest is Test {
    // Represents the precompile address on Centrifuge. Precompile is located at `address(2048)` which is
    // 0x0000000000000000000000000000000000000800 in hex.
    address internal constant PRECOMPILE = 0x0000000000000000000000000000000000000800;

    MockAxelarPrecompile precompile = MockAxelarPrecompile(PRECOMPILE);
    MockAxelarGateway axelarGateway;
    AxelarForwarder forwarder;

    function setUp() public {
        vm.etch(PRECOMPILE, address(new MockAxelarPrecompile()).code);
        axelarGateway = new MockAxelarGateway();
        forwarder = new AxelarForwarder(address(axelarGateway));
    }

    function testDeployment() public {
        new AxelarForwarder(address(axelarGateway));
    }

    function testInvalidFile() public {
        vm.expectRevert("AxelarForwarder/file-unrecognized-param");
        forwarder.file("not-axelar-gateway", address(1));
    }

    function testFileGateway(address invalidOrigin, address anotherAxelarGateway) public {
        vm.assume(invalidOrigin != address(this));

        vm.prank(invalidOrigin);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        forwarder.file("axelarGateway", anotherAxelarGateway);

        forwarder.file("axelarGateway", anotherAxelarGateway);
        assertEq(address(forwarder.axelarGateway()), anotherAxelarGateway);
    }

    function testIncomingCalls(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload,
        address relayer
    ) public {
        vm.assume(relayer.code.length == 0);

        axelarGateway.setReturn("validateContractCall", false);
        vm.prank(address(relayer));
        vm.expectRevert(bytes("AxelarForwarder/not-approved-by-gateway"));
        forwarder.execute(commandId, sourceChain, sourceAddress, payload);

        assertEq(precompile.values_bytes("commandId"), "");
        assertEq(precompile.values_string("sourceChain"), "");
        assertEq(precompile.values_string("sourceAddress"), "");
        assertEq(precompile.values_bytes("payload"), "");

        axelarGateway.setReturn("validateContractCall", true);
        vm.prank(address(relayer));
        forwarder.execute(commandId, sourceChain, sourceAddress, payload);

        assertEq(precompile.values_bytes32("commandId"), commandId);
        assertEq(precompile.values_string("sourceChain"), sourceChain);
        assertEq(precompile.values_string("sourceAddress"), sourceAddress);
        assertEq(precompile.values_bytes("payload"), payload);
    }

    function testExecuteWithTokenReverts(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload,
        string memory tokenSymbol,
        uint256 amount
    ) public {
        vm.expectRevert(bytes("AxelarForwarder/execute-with-token-not-supported"));
        forwarder.executeWithToken(commandId, sourceChain, sourceAddress, payload, tokenSymbol, amount);
    }
}
