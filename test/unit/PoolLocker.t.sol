// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {PoolLocker} from "src/PoolLocker.sol";
import {IPoolLocker} from "src/interfaces/IPoolLocker.sol";

contract UserContract {
    address testAddress;
    uint256 public state;

    constructor(address testAddress_) {
        testAddress = testAddress_;
    }

    function setState() external returns (uint256) {
        state = 100;
        return 23;
    }

    function userFailMethod() external pure {
        revert("user error");
    }
}

contract PoolManagerMock is PoolLocker {
    uint64 public wasUnlock;
    bool public waslock;

    function _unlock(uint64 poolId) internal override {
        wasUnlock = poolId;
    }

    function _lock() internal override {
        waslock = true;
    }

    function poolRelatedMethod() external view poolUnlocked returns (uint64) {
        return unlockedPoolId();
    }
}

contract PoolLockerTest is Test {
    uint64 constant POOL_A = 42;

    UserContract userContract = new UserContract(address(this));
    PoolManagerMock poolManager = new PoolManagerMock();

    function testMultipleCustomCalls() public {
        address[] memory targets = new address[](2);
        targets[0] = address(poolManager);
        targets[1] = address(userContract);

        bytes[] memory methods = new bytes[](2);
        methods[0] = abi.encodeWithSelector(poolManager.poolRelatedMethod.selector);
        methods[1] = abi.encodeWithSelector(userContract.setState.selector);

        bytes[] memory results = poolManager.execute(POOL_A, targets, methods);
        assertEq(abi.decode(results[0], (uint64)), POOL_A);
        assertEq(abi.decode(results[1], (uint256)), 23);

        assertEq(poolManager.wasUnlock(), POOL_A);
        assertEq(poolManager.waslock(), true);
        assertEq(userContract.state(), 100);
    }

    function testRevertAtError() public {
        // Will revert the whole transaction when the first error appears

        address[] memory targets = new address[](2);
        targets[0] = address(userContract);
        targets[1] = address(userContract);

        bytes[] memory methods = new bytes[](2);
        methods[0] = abi.encodeWithSelector(userContract.setState.selector);
        methods[1] = abi.encodeWithSelector(userContract.userFailMethod.selector);

        vm.expectRevert("user error");
        poolManager.execute(POOL_A, targets, methods);

        assertEq(userContract.state(), 0);
    }

    function testErrPoolAlreadyUnlocked() public {
        address[] memory innerTargets = new address[](1);
        innerTargets[0] = address(poolManager);

        bytes[] memory innerMethods = new bytes[](1);
        innerMethods[0] = abi.encodeWithSelector(poolManager.poolRelatedMethod.selector);

        address[] memory targets = new address[](1);
        targets[0] = address(poolManager);

        bytes[] memory methods = new bytes[](1);
        methods[0] = abi.encodeWithSelector(poolManager.execute.selector, POOL_A, innerTargets, innerMethods);

        vm.expectRevert(IPoolLocker.PoolAlreadyUnlocked.selector);
        poolManager.execute(POOL_A, targets, methods);
    }

    function testErrWrongExecutionParams() public {
        address[] memory targets = new address[](1);
        bytes[] memory methods = new bytes[](2);

        vm.expectRevert(IPoolLocker.WrongExecutionParams.selector);
        poolManager.execute(POOL_A, targets, methods);
    }

    function testErrPoolLocked() public {
        vm.expectRevert(IPoolLocker.PoolLocked.selector);
        poolManager.poolRelatedMethod();
    }
}
