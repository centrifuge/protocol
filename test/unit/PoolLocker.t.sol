// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {PoolLocker} from "src/PoolLocker.sol";

contract UserContract {
    address testAddress;
    uint256 public state = 1;

    constructor(address testAddress_) {
        testAddress = testAddress_;
    }

    function userMethod() external returns (uint256) {
        state = 100;
        return 23;
    }
}

contract PoolManagerMock is PoolLocker {
    function _unlock(uint64 poolId) internal override {
        // Do something
    }

    function _lock() internal override {
        // Do something
    }

    function poolRelatedMethod() external poolUnlocked returns (uint64) {
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
        methods[1] = abi.encodeWithSelector(userContract.userMethod.selector);

        bytes[] memory results = poolManager.execute(POOL_A, targets, methods);
        assertEq(abi.decode(results[0], (uint64)), POOL_A);
        assertEq(abi.decode(results[1], (uint256)), 23);

        assertEq(userContract.state(), 100);
    }
}
