// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {PoolId} from "src/types/PoolId.sol";
import {PoolLocker} from "src/PoolLocker.sol";
import {IPoolLocker} from "src/interfaces/IPoolLocker.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";
import {ICallEscrow} from "src/interfaces/ICallEscrow.sol";
import {Multicall} from "src/Multicall.sol";

contract PoolManagerMock is PoolLocker {
    PoolId public wasUnlockWithPool;
    bool public wasLock;

    constructor(IMulticall multicall) PoolLocker(multicall) {}

    function poolRelatedMethod() external view poolUnlocked returns (PoolId) {
        return unlockedPoolId();
    }

    function _beforeUnlock(PoolId poolId) internal override returns (ICallEscrow) {
        wasUnlockWithPool = poolId;
        return ICallEscrow(address(0));
    }

    function _beforeLock() internal override {
        wasLock = true;
    }
}

contract PoolLockerTest is Test {
    PoolId constant POOL_A = PoolId.wrap(42);

    Multicall multicall = new Multicall();
    PoolManagerMock poolManager = new PoolManagerMock(multicall);

    function testWithPoolUnlockerMethod() public {
        IMulticall.Call[] memory calls = new IMulticall.Call[](1);
        calls[0] = IMulticall.Call(address(poolManager), abi.encodeWithSelector(poolManager.poolRelatedMethod.selector));

        bytes[] memory results = poolManager.execute(POOL_A, calls);
        assertEq(PoolId.unwrap(abi.decode(results[0], (PoolId))), PoolId.unwrap(POOL_A));

        assertEq(PoolId.unwrap(poolManager.wasUnlockWithPool()), PoolId.unwrap(POOL_A));
        assertEq(poolManager.wasLock(), true);
    }

    function testErrPoolAlreadyUnlocked() public {
        IMulticall.Call[] memory innerCalls = new IMulticall.Call[](1);
        innerCalls[0] =
            IMulticall.Call(address(poolManager), abi.encodeWithSelector(poolManager.poolRelatedMethod.selector));

        IMulticall.Call[] memory calls = new IMulticall.Call[](1);
        calls[0] = IMulticall.Call(
            address(poolManager), abi.encodeWithSelector(poolManager.execute.selector, POOL_A, innerCalls)
        );

        vm.expectRevert(IPoolLocker.PoolAlreadyUnlocked.selector);
        poolManager.execute(POOL_A, calls);
    }

    function testErrPoolLocked() public {
        vm.expectRevert(IPoolLocker.PoolLocked.selector);
        poolManager.poolRelatedMethod();
    }
}
