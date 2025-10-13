// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGateway} from "../../../src/core/interfaces/IGateway.sol";
import {BatchedMulticall} from "../../../src/core/utils/BatchedMulticall.sol";

import "forge-std/Test.sol";

contract BatchedMulticallImpl is BatchedMulticall, Test {
    uint256 public total;

    constructor(IGateway gateway) BatchedMulticall(gateway) {}

    function isBatching() external view returns (bool) {
        return _isBatching;
    }

    function nonZeroPayment() external payable {
        assertNotEq(_payment(), 0);
    }

    function add(uint256 i) external payable {
        assertEq(_payment(), 0);
        total += i;
    }
}

contract IsContract {}

contract BatchedMulticallTest is Test {
    IGateway immutable gateway = IGateway(address(new IsContract()));
    BatchedMulticallImpl multicall = new BatchedMulticallImpl(gateway);

    function setUp() external {}
}

contract BatchedMulticallTestMulticall is BatchedMulticallTest {
    function _foo() external {}

    function testPaymentIsNonZeroWithoutMulticall() external {
        multicall.nonZeroPayment{value: 1}();
    }

    function testErrAlreadyBatching() external {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.startBatching.selector), abi.encode());
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.endBatching.selector), abi.encode());

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(multicall.add.selector, 1);

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

        multicall.multicall{value: 1}(calls);

        assertEq(multicall.isBatching(), false);
        assertEq(multicall.total(), 5);
    }
}
