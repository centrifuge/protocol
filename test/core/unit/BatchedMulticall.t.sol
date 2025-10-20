// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGateway} from "../../../src/core/messaging/interfaces/IGateway.sol";
import {BatchedMulticall} from "../../../src/core/utils/BatchedMulticall.sol";
import {IBatchedMulticall} from "../../../src/core/utils/interfaces/IBatchedMulticall.sol";

import "forge-std/Test.sol";

contract BatchedMulticallImpl is BatchedMulticall, Test {
    uint256 public total;

    constructor(IGateway gateway) BatchedMulticall(gateway) {}

    function nonZeroPayment() external payable {
        assertNotEq(msgValue(), 0);
    }

    function add(uint256 i) external payable {
        assertEq(msgValue(), 0);
        total += i;
    }
}

contract MockGateway {
    address internal transient _batcher;

    function withBatch(bytes memory data, address) external payable {
        _batcher = msg.sender;
        (bool success, bytes memory returnData) = msg.sender.call(data);
        if (!success) {
            uint256 length = returnData.length;
            require(length != 0, "call-failed-empty-revert");

            assembly ("memory-safe") {
                revert(add(32, returnData), length)
            }
        }
    }

    function lockCallback() external returns (address caller) {
        caller = _batcher;
        _batcher = address(0);
    }
}

contract BatchedMulticallTest is Test {
    IGateway immutable gateway = IGateway(address(new MockGateway()));
    BatchedMulticallImpl multicall = new BatchedMulticallImpl(gateway);

    function setUp() external {}
}

contract BatchedMulticallTestMulticall is BatchedMulticallTest {
    function _foo() external {}

    function testPaymentIsNonZeroWithoutMulticall() external {
        multicall.nonZeroPayment{value: 1}();
    }

    function testMulticallTest() external {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(multicall.add.selector, 2);
        calls[1] = abi.encodeWithSelector(multicall.add.selector, 3);

        multicall.multicall{value: 1}(calls);

        assertEq(multicall.total(), 5);
    }

    function testNestedMulticallIsBlocked() external {
        bytes[] memory innerCalls = new bytes[](1);
        innerCalls[0] = abi.encodeWithSelector(multicall.add.selector);

        bytes[] memory outerCalls = new bytes[](1);
        outerCalls[0] = abi.encodeWithSelector(multicall.multicall.selector, innerCalls);

        vm.expectRevert(IBatchedMulticall.AlreadyBatching.selector);
        multicall.multicall{value: 1}(outerCalls);
    }
}
