// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {Multicall} from "src/Multicall.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";

contract UserContract {
    uint256 public state;

    function setState() external returns (uint256) {
        state += 100;
        return 23;
    }

    function userFailMethod() external pure {
        revert("user error");
    }
}

contract MulticallTest is Test {
    UserContract userContract = new UserContract();
    Multicall multicall = new Multicall();

    function testSuccess() public {
        // Will revert the whole transaction when the first error appears

        address[] memory targets = new address[](2);
        targets[0] = address(userContract);
        targets[1] = address(userContract);

        bytes[] memory methods = new bytes[](2);
        methods[0] = abi.encodeWithSelector(userContract.setState.selector);
        methods[1] = abi.encodeWithSelector(userContract.setState.selector);

        multicall.aggregate(targets, methods);

        assertEq(userContract.state(), 200);
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
        multicall.aggregate(targets, methods);

        assertEq(userContract.state(), 0);
    }

    function testErrWrongExecutionParams() public {
        address[] memory targets = new address[](1);
        bytes[] memory methods = new bytes[](2);

        vm.expectRevert(IMulticall.WrongExecutionParams.selector);
        multicall.aggregate(targets, methods);
    }
}
