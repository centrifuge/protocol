// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGateway} from "../../../src/core/messaging/interfaces/IGateway.sol";
import {CrosschainBatcher} from "../../../src/core/messaging/CrosschainBatcher.sol";
import {BatchedMulticall} from "../../../src/core/utils/BatchedMulticall.sol";

import "forge-std/Test.sol";

contract BatchedMulticallImpl is BatchedMulticall, Test {
    uint256 public total;

    constructor(CrosschainBatcher batcher_) BatchedMulticall(batcher_) {}

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

    function startBatching() external {
        _batcher = msg.sender;
    }

    function endBatching(address) external payable {
        _batcher = address(0);
    }

    function batcher() external view returns (address) {
        return _batcher;
    }
}

contract BatchedMulticallTest is Test {
    MockGateway mockGateway = new MockGateway();
    IGateway gateway = IGateway(address(mockGateway));
    CrosschainBatcher batcher = new CrosschainBatcher(gateway, address(this));
    BatchedMulticallImpl multicall;

    function setUp() external {
        multicall = new BatchedMulticallImpl(batcher);
    }
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
}
