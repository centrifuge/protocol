// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {IMulticall} from "src/misc/interfaces/IMulticall.sol";
import {Multicall} from "src/misc/Multicall.sol";

contract ExternalContract {
    MulticallImpl public multicall;

    constructor(MulticallImpl multicall_) {
        multicall = multicall_;
    }

    function add(uint256 value_) public {
        multicall.add(value_);
    }
}

contract MulticallImpl is Multicall {
    uint256 public value;
    ExternalContract public ext;

    function setExternalContract(ExternalContract ext_) public {
        ext = ext_;
    }

    function add(uint256 value_) external protected {
        value += value_;
    }

    function err() external protected {
        revert("error");
    }

    function addWithReentrancy(uint256 value_) external protected {
        ext.add(value_);
    }
}

contract MulticallTest is Test {
    MulticallImpl multicall = new MulticallImpl();
    ExternalContract ext = new ExternalContract(multicall);

    function setUp() public {
        multicall.setExternalContract(ext);
    }

    function testSuccess() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(multicall.add.selector, 2);
        calls[1] = abi.encodeWithSelector(multicall.add.selector, 3);

        multicall.multicall(calls);

        assertEq(multicall.value(), 5);
    }

    function testSeveralMulticallsInSingleTransaction() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(multicall.add.selector, 2);
        calls[1] = abi.encodeWithSelector(multicall.add.selector, 3);

        multicall.multicall(calls);
        // Initiator should be 0 at this point

        multicall.multicall(calls);

        assertEq(multicall.value(), 10);
    }

    function testRevertAtError() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(multicall.add.selector, 2);
        calls[1] = abi.encodeWithSelector(multicall.err.selector);

        vm.expectRevert("error");
        multicall.multicall(calls);

        // Will revert the whole transaction when the first error appears
        assertEq(multicall.value(), 0);
    }

    function testErrAlreadyInitiated() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(multicall.multicall.selector, new bytes[](0));

        vm.expectRevert(IMulticall.AlreadyInitiated.selector);
        multicall.multicall(calls);
    }

    function testErrUnauthorizedSender() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(multicall.addWithReentrancy.selector, 2);

        vm.expectRevert(IMulticall.UnauthorizedSender.selector);
        multicall.multicall(calls);
    }
}
