// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/Auth.sol";

import {IGateway} from "../../../src/common/interfaces/IGateway.sol";
import {CrosschainBatcher, ICrosschainBatcher} from "../../../src/common/CrosschainBatcher.sol";

import "forge-std/Test.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract CrosschainBatcherTest is Test {
    IGateway gateway = IGateway(address(new IsContract()));

    address immutable ANY = makeAddr("owner");
    address immutable AUTH = makeAddr("unauthorized");

    uint256 constant COST = 100;
    uint256 constant PAYMENT = 1000;

    CrosschainBatcher batcher = new CrosschainBatcher(gateway, AUTH);
}

contract CrosschainBatcherTestFile is CrosschainBatcherTest {
    function testErrNotAuthorizedSafe() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        batcher.file("gateway", address(123));
    }

    function testErrFileUnrecognizedParam() public {
        vm.startPrank(AUTH);
        vm.expectRevert(ICrosschainBatcher.FileUnrecognizedParam.selector);
        batcher.file("unknown", address(123));
    }

    function testFile() public {
        vm.startPrank(AUTH);
        batcher.file("gateway", address(123));
        assertEq(address(batcher.gateway()), address(123));
    }
}

contract CrosschainBatcherTestWithBatch is CrosschainBatcherTest {
    bool wasCalled;

    function setUp() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.startBatching.selector), abi.encode());
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.endBatching.selector), abi.encode(COST));
    }

    function _success(bool, uint256) external payable {
        require(batcher.caller() == address(this));
        wasCalled = true;
        assertEq(msg.value, PAYMENT);
    }

    function _nested() external payable {
        batcher.execute(abi.encodeWithSelector(CrosschainBatcherTestWithBatch._nested.selector));
    }

    function _emptyError() external payable {
        revert();
    }

    /// forge-config: default.isolate = true
    function testErrAlreadyBatching() public {
        vm.expectRevert(ICrosschainBatcher.AlreadyBatching.selector);
        batcher.execute(abi.encodeWithSelector(CrosschainBatcherTestWithBatch._nested.selector));
    }

    /// forge-config: default.isolate = true
    function testErrCallFailedWithEmptyRevert() public {
        vm.expectRevert(ICrosschainBatcher.CallFailedWithEmptyRevert.selector);
        batcher.execute(abi.encodeWithSelector(CrosschainBatcherTestWithBatch._emptyError.selector));
    }

    /// forge-config: default.isolate = true
    function testWithCallback() public {
        vm.prank(ANY);
        vm.deal(ANY, PAYMENT);
        uint256 cost = batcher.execute{
            value: PAYMENT
        }(abi.encodeWithSelector(CrosschainBatcherTestWithBatch._success.selector, true, 1));
        assertEq(cost, COST);
        assertEq(batcher.caller(), address(0));
    }
}
