// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGateway} from "../../../src/common/interfaces/IGateway.sol";
import {BatchedMulticall} from "../../../src/common/BatchedMulticall.sol";

import "forge-std/Test.sol";

contract BatchedMulticallImpl is BatchedMulticall, Test {
    uint256 total;

    constructor(IGateway gateway) BatchedMulticall(gateway) {}

    function isBatching() external view returns (bool) {
        return _isBatching;
    }

    function add(uint256 i) external {
        assertEq(_payment(), 0);
        total += i;
    }
}

contract IsContract {}

contract BatchedMulticallTest is Test {
    address immutable ANY = makeAddr("any");

    IGateway immutable gateway = IGateway(address(new IsContract()));
    BatchedMulticallImpl multicall = new BatchedMulticallImpl(gateway);

    function setUp() external {}
}

contract BatchedMulticallTestMulticall is BatchedMulticallTest {
    function _foo() external {}

    function testErrAlreadyBatching() external {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.startBatching.selector), abi.encode());
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.endBatching.selector), abi.encode());

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(multicall.add.selector, 1);

        vm.prank(ANY);
        vm.expectRevert(IGateway.AlreadyBatching.selector);
        multicall.multicall(calls);
    }

    function testMulticall() external {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(false));
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.startBatching.selector), abi.encode());
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.endBatching.selector), abi.encode());

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(multicall.add.selector, 2);
        calls[1] = abi.encodeWithSelector(multicall.add.selector, 3);

        vm.prank(ANY);
        multicall.multicall(calls);

        assertEq(multicall.isBatching(), false);
    }
}
