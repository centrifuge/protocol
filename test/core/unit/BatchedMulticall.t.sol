// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGateway} from "../../../src/core/messaging/interfaces/IGateway.sol";
import {BatchedMulticall} from "../../../src/core/utils/BatchedMulticall.sol";
import {IBatchedMulticall} from "../../../src/core/utils/interfaces/IBatchedMulticall.sol";

import "forge-std/Test.sol";

contract BatchedMulticallImpl is BatchedMulticall, Test {
    uint256 public total;
    ReentrantHook public hook;

    constructor(IGateway gateway) BatchedMulticall(gateway) {}

    function nonZeroPayment() external payable {
        assertNotEq(msgValue(), 0);
    }

    function add(uint256 i) external payable {
        assertEq(msgValue(), 0);
        total += i;
    }

    function setHook(ReentrantHook hook_) external payable {
        hook = hook_;
    }

    /// @dev Simulates an inner batched call that hands control to an external hook.
    function triggerHook() external payable {
        hook.onSync();
    }

    /// @dev Entry point used by the reentrant hook. Because msg.sender is the hook (not the
    ///      gateway), the real msg.value must be visible even though a batch is active.
    function reentrantPayment() external payable {
        assertEq(msgValue(), 5);
    }
}

contract ReentrantHook {
    BatchedMulticallImpl immutable impl;

    constructor(BatchedMulticallImpl impl_) {
        impl = impl_;
    }

    function onSync() external {
        impl.reentrantPayment{value: 5}();
    }

    receive() external payable {}
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

    function testReentrantCallDuringBatchKeepsRealValue() external {
        // A reentrant call entering during an active batch from a non-gateway sender (an external
        // hook) must see its real msg.value, otherwise the attached ETH is silently dropped.
        ReentrantHook hook = new ReentrantHook(multicall);
        vm.deal(address(hook), 5);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(multicall.setHook.selector, hook);
        calls[1] = abi.encodeWithSelector(multicall.triggerHook.selector);

        multicall.multicall(calls);
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
