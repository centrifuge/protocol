// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Multicall} from "../../../src/misc/Multicall.sol";
import {IMulticall} from "../../../src/misc/interfaces/IMulticall.sol";
import {ReentrancyProtection} from "../../../src/misc/ReentrancyProtection.sol";

import "forge-std/Test.sol";

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

    function errEmpty() external protected {
        revert();
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

        // It reverts the whole transaction when the first error appears
        assertEq(multicall.value(), 0);
    }

    function testErrCallFailedWithEmptyRevert() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(multicall.errEmpty.selector);

        vm.expectRevert(IMulticall.CallFailedWithEmptyRevert.selector);
        multicall.multicall(calls);
    }

    function testErrUnauthorizedSender() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(multicall.addWithReentrancy.selector, 2);

        vm.expectRevert(ReentrancyProtection.UnauthorizedSender.selector);
        multicall.multicall(calls);
    }
}
