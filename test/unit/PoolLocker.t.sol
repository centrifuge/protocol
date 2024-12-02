// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {PoolLocker} from "src/PoolLocker.sol";
import {IPoolLocker} from "src/interfaces/IPoolLocker.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";
import {Multicall} from "src/Multicall.sol";

contract PoolManagerMock is PoolLocker {
    uint64 public wasUnlockWithPool;
    bool public waslock;

    constructor(IMulticall multicall) PoolLocker(multicall) {}

    function _unlock(uint64 poolId) internal override {
        wasUnlockWithPool = poolId;
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

    Multicall multicall = new Multicall();
    PoolManagerMock poolManager = new PoolManagerMock(multicall);

    function testWithPoolUnlockerMethod() public {
        address[] memory targets = new address[](1);
        targets[0] = address(poolManager);

        bytes[] memory methods = new bytes[](1);
        methods[0] = abi.encodeWithSelector(poolManager.poolRelatedMethod.selector);

        bytes[] memory results = poolManager.execute(POOL_A, targets, methods);
        assertEq(abi.decode(results[0], (uint64)), POOL_A);

        assertEq(poolManager.wasUnlockWithPool(), POOL_A);
        assertEq(poolManager.waslock(), true);
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

    function testErrPoolLocked() public {
        vm.expectRevert(IPoolLocker.PoolLocked.selector);
        poolManager.poolRelatedMethod();
    }
}
