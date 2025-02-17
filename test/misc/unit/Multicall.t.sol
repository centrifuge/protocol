// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {IMulticall} from "src/misc/interfaces/IMulticall.sol";
import {Multicall} from "src/misc/Multicall.sol";

contract UserContract {
    uint256 public state;

    function updateState() external returns (uint256) {
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

        IMulticall.Call[] memory calls = new IMulticall.Call[](2);
        calls[0] = IMulticall.Call(address(userContract), abi.encodeWithSelector(userContract.updateState.selector));
        calls[1] = IMulticall.Call(address(userContract), abi.encodeWithSelector(userContract.updateState.selector));

        multicall.aggregate(calls);

        assertEq(userContract.state(), 200);
    }

    function testRevertAtError() public {
        // Will revert the whole transaction when the first error appears

        IMulticall.Call[] memory calls = new IMulticall.Call[](2);
        calls[0] = IMulticall.Call(address(userContract), abi.encodeWithSelector(userContract.updateState.selector));
        calls[1] = IMulticall.Call(address(userContract), abi.encodeWithSelector(userContract.userFailMethod.selector));

        vm.expectRevert("user error");
        multicall.aggregate(calls);

        assertEq(userContract.state(), 0);
    }
}
