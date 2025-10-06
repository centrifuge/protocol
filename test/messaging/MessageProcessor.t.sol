// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";

import {MessageProcessor} from "../../src/core/messaging/MessageProcessor.sol";
import {IScheduleAuth} from "../../src/core/messaging/interfaces/IScheduleAuth.sol";
import {IMessageProcessor} from "../../src/core/messaging/interfaces/IMessageProcessor.sol";

import "forge-std/Test.sol";

contract TestCommon is Test {
    address immutable ANY = makeAddr("any");
    address immutable AUTH = makeAddr("auth");

    MessageProcessor processor;
    IScheduleAuth immutable scheduleAuth = IScheduleAuth(makeAddr("ScheduleAuth"));

    function setUp() external {
        processor = new MessageProcessor(scheduleAuth, AUTH);
    }
}

contract TestAuthChecks is TestCommon {
    function testErrNotAuthorized() public {
        vm.startPrank(ANY);

        bytes memory EMPTY_MESSAGE;

        vm.expectRevert(IAuth.NotAuthorized.selector);
        processor.handle(1, EMPTY_MESSAGE);

        vm.stopPrank();
    }
}

contract TestFile is TestCommon {
    function testErrNotAuthorized() public {
        vm.prank(address(ANY));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        processor.file("gateway", address(0));
    }

    function testErrFileUnrecognizedParam() public {
        vm.prank(address(AUTH));
        vm.expectRevert(IMessageProcessor.FileUnrecognizedParam.selector);
        processor.file("unknown", address(0));
    }

    function testFileGateway() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("gateway", address(23));
        processor.file("gateway", address(23));
        assertEq(address(processor.gateway()), address(23));
    }

    function testFileMultiAdapter() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("multiAdapter", address(23));
        processor.file("multiAdapter", address(23));
        assertEq(address(processor.multiAdapter()), address(23));
    }

    function testFileHubHandler() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("hubHandler", address(23));
        processor.file("hubHandler", address(23));
        assertEq(address(processor.hubHandler()), address(23));
    }

    function testFileSpoke() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("spoke", address(23));
        processor.file("spoke", address(23));
        assertEq(address(processor.spoke()), address(23));
    }

    function testFileBalanceSheet() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("balanceSheet", address(23));
        processor.file("balanceSheet", address(23));
        assertEq(address(processor.balanceSheet()), address(23));
    }

    function testFileVaultRegistry() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("vaultRegistry", address(23));
        processor.file("vaultRegistry", address(23));
        assertEq(address(processor.vaultRegistry()), address(23));
    }

    function testFileContractUpdater() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("contractUpdater", address(23));
        processor.file("contractUpdater", address(23));
        assertEq(address(processor.contractUpdater()), address(23));
    }

    function testFileTokenRecoverer() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("tokenRecoverer", address(23));
        processor.file("tokenRecoverer", address(23));
        assertEq(address(processor.tokenRecoverer()), address(23));
    }
}
