// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {Root, IRoot} from "../../../src/common/Root.sol";

import "forge-std/Test.sol";

contract RootTest is Test {
    uint256 constant DELAY = 48 hours;
    uint256 constant MAX_DELAY = 4 weeks; // From Root.MAX_DELAY internal constant

    address immutable AUTH = makeAddr("auth");
    address immutable ANY = makeAddr("any");
    address immutable USER = makeAddr("user");
    address immutable TARGET = makeAddr("target");

    Root root = new Root(DELAY, AUTH);

    function testConstructor() public view {
        assertEq(root.delay(), DELAY);
    }

    function testWrongDelay() public {
        vm.expectRevert(IRoot.DelayTooLong.selector);
        new Root(MAX_DELAY + 1, AUTH);
    }
}

contract RootTestFile is RootTest {
    function testErrNotAuthorized() public {
        vm.prank(address(ANY));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        root.file("delay", 1);
    }

    function testErrFileUnrecognizedParam() public {
        vm.prank(address(AUTH));
        vm.expectRevert(IRoot.FileUnrecognizedParam.selector);
        root.file("unknown", 1);
    }

    function testErrDelayTooLong() public {
        vm.prank(address(AUTH));
        vm.expectRevert(IRoot.DelayTooLong.selector);
        root.file("delay", MAX_DELAY + 1);
    }

    function testFileDelay() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IRoot.File("delay", 1);
        root.file("delay", 1);

        assertEq(root.delay(), 1);
    }
}

contract RootTestEndorse is RootTest {
    function testErrNotAuthorized() public {
        vm.prank(address(ANY));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        root.endorse(USER);
    }

    function testEndorse() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IRoot.Endorse(USER);
        root.endorse(USER);

        assertEq(root.endorsed(USER), true);
    }
}

contract RootTestVeto is RootTest {
    function testErrNotAuthorized() public {
        vm.prank(address(ANY));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        root.veto(USER);
    }

    function testVeto() public {
        vm.prank(address(AUTH));
        root.endorse(USER);

        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IRoot.Veto(USER);
        root.veto(USER);

        assertEq(root.endorsed(USER), false);
    }
}

contract RootTestPause is RootTest {
    function testErrNotAuthorized() public {
        vm.prank(address(ANY));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        root.pause();
    }

    function testPause() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IRoot.Pause();
        root.pause();

        assertEq(root.paused(), true);
    }
}

contract RootTestUnpause is RootTest {
    function testErrNotAuthorized() public {
        vm.prank(address(ANY));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        root.unpause();
    }

    function testUnpause() public {
        vm.prank(address(AUTH));
        root.pause();

        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IRoot.Unpause();
        root.unpause();

        assertEq(root.paused(), false);
    }
}

contract RootTestScheduleRely is RootTest {
    function testErrNotAuthorized() public {
        vm.prank(address(ANY));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        root.scheduleRely(TARGET);
    }

    function testScheduleRely() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IRoot.ScheduleRely(TARGET, block.timestamp + DELAY);
        root.scheduleRely(TARGET);

        assertEq(root.schedule(TARGET), block.timestamp + DELAY);
    }
}

contract RootTestCancelRely is RootTest {
    function testErrNotAuthorized() public {
        vm.prank(address(ANY));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        root.cancelRely(TARGET);
    }

    function testErrTargetNotScheduled() public {
        vm.prank(address(AUTH));
        vm.expectRevert(IRoot.TargetNotScheduled.selector);
        root.cancelRely(TARGET);
    }

    function testCancelRely() public {
        vm.prank(address(AUTH));
        root.scheduleRely(TARGET);

        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IRoot.CancelRely(TARGET);
        root.cancelRely(TARGET);

        assertEq(root.schedule(TARGET), 0);
    }
}

contract RootTestExecuteScheduleRely is RootTest {
    function testErrTargetNotScheduled() public {
        vm.prank(address(AUTH));
        vm.expectRevert(IRoot.TargetNotScheduled.selector);
        root.executeScheduledRely(TARGET);
    }

    function testErrTargetNotReady() public {
        vm.prank(address(AUTH));
        root.scheduleRely(TARGET);

        vm.prank(address(AUTH));
        vm.expectRevert(IRoot.TargetNotReady.selector);
        root.executeScheduledRely(TARGET);
    }

    function testExecuteScheduleRely() public {
        vm.prank(address(AUTH));
        root.scheduleRely(TARGET);

        vm.warp(block.timestamp + DELAY);

        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IAuth.Rely(TARGET);
        root.executeScheduledRely(TARGET);

        assertEq(root.wards(TARGET), 1);
        assertEq(root.schedule(TARGET), 0);
    }
}

contract RootTestRelyContract is RootTest {
    function testErrNotAuthorized() public {
        vm.prank(address(ANY));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        root.relyContract(TARGET, USER);
    }

    function testRelyContract() public {
        vm.mockCall(address(TARGET), abi.encodeWithSelector(IAuth.rely.selector, USER), abi.encode());

        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IRoot.RelyContract(TARGET, USER);
        root.relyContract(TARGET, USER);
    }
}

contract RootTestDenyContract is RootTest {
    function testErrNotAuthorized() public {
        vm.prank(address(ANY));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        root.denyContract(TARGET, USER);
    }

    function testDenyContract() public {
        vm.mockCall(address(TARGET), abi.encodeWithSelector(IAuth.deny.selector, USER), abi.encode());

        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IRoot.DenyContract(TARGET, USER);
        root.denyContract(TARGET, USER);
    }
}
