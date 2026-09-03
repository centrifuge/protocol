// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IScheduleAuthMessageSender} from "../../../src/core/messaging/interfaces/IGatewaySenders.sol";

import {IRoot} from "../../../src/admin/interfaces/IRoot.sol";
import {ISafe} from "../../../src/admin/interfaces/ISafe.sol";
import {ProtocolGuardian} from "../../../src/admin/ProtocolGuardian.sol";
import {IProtocolGuardian} from "../../../src/admin/interfaces/IProtocolGuardian.sol";

import "forge-std/Test.sol";

import {ITokenBridge} from "../../../src/bridge/interfaces/ITokenBridge.sol";

contract IsContract {}

contract ProtocolGuardianTest is Test {
    using CastLib for address;

    IRoot immutable root = IRoot(address(new IsContract()));
    ISafe immutable SAFE = ISafe(address(new IsContract()));
    IScheduleAuthMessageSender immutable sender = IScheduleAuthMessageSender(address(new IsContract()));
    ITokenBridge immutable tokenBridge = ITokenBridge(address(new IsContract()));

    address immutable OWNER = makeAddr("owner");
    address immutable UNAUTHORIZED = makeAddr("unauthorized");
    address immutable TARGET = makeAddr("target");
    address immutable REFUND = makeAddr("refund");
    IAdapter immutable ADAPTER = IAdapter(makeAddr("adapter"));

    uint16 constant CENTRIFUGE_ID = 1;
    uint256 constant COST = 123;
    ProtocolGuardian protocolGuardian;

    function setUp() public {
        protocolGuardian = new ProtocolGuardian(SAFE, root, sender, tokenBridge);
        vm.deal(address(SAFE), 1 ether);
    }

    function testProtocolGuardian() public view {
        assertEq(address(protocolGuardian.safe()), address(SAFE));
        assertEq(address(protocolGuardian.root()), address(root));
        assertEq(address(protocolGuardian.sender()), address(sender));
        assertEq(address(protocolGuardian.tokenBridge()), address(tokenBridge));
    }
}

contract ProtocolGuardianTestPause is ProtocolGuardianTest {
    function testPauseSuccessWithSafe() public {
        vm.mockCall(address(root), abi.encodeWithSelector(root.pause.selector), abi.encode());
        vm.expectCall(address(root), abi.encodeWithSelector(root.pause.selector));

        vm.prank(address(SAFE));
        protocolGuardian.pause();
    }

    function testPauseSuccessWithOwner() public {
        vm.mockCall(address(root), abi.encodeWithSelector(root.pause.selector), abi.encode());
        vm.mockCall(address(SAFE), abi.encodeWithSelector(ISafe.isOwner.selector, OWNER), abi.encode(true));

        vm.prank(OWNER);
        protocolGuardian.pause();
    }

    function testPauseRevertWhenUnauthorizedCaller() public {
        vm.mockCall(address(SAFE), abi.encodeWithSelector(ISafe.isOwner.selector, UNAUTHORIZED), abi.encode(false));

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IProtocolGuardian.NotTheAuthorizedSafeOrItsOwner.selector);
        protocolGuardian.pause();
    }

    function testPauseGracefulHandlingWhenSafeIsOwnerReverts() public {
        vm.mockCallRevert(address(SAFE), abi.encodeWithSelector(ISafe.isOwner.selector, UNAUTHORIZED), "revert");

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IProtocolGuardian.NotTheAuthorizedSafeOrItsOwner.selector);
        protocolGuardian.pause();
    }
}

contract ProtocolGuardianTestUnpause is ProtocolGuardianTest {
    function testUnpauseSuccess() public {
        vm.mockCall(address(root), abi.encodeWithSelector(root.unpause.selector), abi.encode());
        vm.expectCall(address(root), abi.encodeWithSelector(root.unpause.selector));

        vm.prank(address(SAFE));
        protocolGuardian.unpause();
    }

    function testUnpauseRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IProtocolGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.unpause();
    }

    function testUnpauseRevertWhenOwner() public {
        vm.prank(OWNER);
        vm.expectRevert(IProtocolGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.unpause();
    }
}

contract ProtocolGuardianTestScheduleRely is ProtocolGuardianTest {
    function testScheduleRelySuccess() public {
        vm.mockCall(address(root), abi.encodeWithSelector(root.scheduleRely.selector, TARGET), abi.encode());
        vm.expectCall(address(root), abi.encodeWithSelector(root.scheduleRely.selector, TARGET));

        vm.prank(address(SAFE));
        protocolGuardian.scheduleRely(TARGET);
    }

    function testScheduleRelyRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IProtocolGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.scheduleRely(TARGET);
    }
}

contract ProtocolGuardianTestCancelRely is ProtocolGuardianTest {
    function testCancelRelySuccess() public {
        vm.mockCall(address(root), abi.encodeWithSelector(root.cancelRely.selector, TARGET), abi.encode());
        vm.expectCall(address(root), abi.encodeWithSelector(root.cancelRely.selector, TARGET));

        vm.prank(address(SAFE));
        protocolGuardian.cancelRely(TARGET);
    }

    function testCancelRelyRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IProtocolGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.cancelRely(TARGET);
    }
}

contract ProtocolGuardianTestScheduleUpgrade is ProtocolGuardianTest {
    using CastLib for address;

    function testScheduleUpgradeSuccess() public {
        vm.mockCall(
            address(sender),
            COST,
            abi.encodeWithSelector(sender.sendScheduleUpgrade.selector, CENTRIFUGE_ID, TARGET.toBytes32(), REFUND),
            abi.encode()
        );
        vm.expectCall(
            address(sender),
            abi.encodeWithSelector(sender.sendScheduleUpgrade.selector, CENTRIFUGE_ID, TARGET.toBytes32(), REFUND)
        );

        vm.prank(address(SAFE));
        protocolGuardian.scheduleUpgrade{value: COST}(CENTRIFUGE_ID, TARGET, REFUND);
    }

    function testScheduleUpgradeRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IProtocolGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.scheduleUpgrade(CENTRIFUGE_ID, TARGET, REFUND);
    }
}

contract ProtocolGuardianTestCancelUpgrade is ProtocolGuardianTest {
    using CastLib for address;

    function testCancelUpgradeSuccess() public {
        vm.mockCall(
            address(sender),
            COST,
            abi.encodeWithSelector(sender.sendCancelUpgrade.selector, CENTRIFUGE_ID, TARGET.toBytes32(), REFUND),
            abi.encode()
        );
        vm.expectCall(
            address(sender),
            abi.encodeWithSelector(sender.sendCancelUpgrade.selector, CENTRIFUGE_ID, TARGET.toBytes32(), REFUND)
        );

        vm.prank(address(SAFE));
        protocolGuardian.cancelUpgrade{value: COST}(CENTRIFUGE_ID, TARGET, REFUND);
    }

    function testCancelUpgradeRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IProtocolGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.cancelUpgrade(CENTRIFUGE_ID, TARGET, REFUND);
    }
}

contract ProtocolGuardianTestFile is ProtocolGuardianTest {
    function testFileSafeSuccess() public {
        address newSafe = makeAddr("newSafe");

        vm.expectEmit();
        emit IProtocolGuardian.File("safe", newSafe);

        vm.prank(address(SAFE));
        protocolGuardian.file("safe", newSafe);

        assertEq(address(protocolGuardian.safe()), newSafe);
    }

    function testFileSenderSuccess() public {
        address newSender = makeAddr("newSender");

        vm.expectEmit();
        emit IProtocolGuardian.File("sender", newSender);

        vm.prank(address(SAFE));
        protocolGuardian.file("sender", newSender);

        assertEq(address(protocolGuardian.sender()), newSender);
    }

    function testFileRevertWhenUnrecognizedParam() public {
        vm.prank(address(SAFE));
        vm.expectRevert(IProtocolGuardian.FileUnrecognizedParam.selector);
        protocolGuardian.file("invalid", makeAddr("address"));
    }

    function testFileTokenBridgeSuccess() public {
        address newTokenBridge = makeAddr("newTokenBridge");

        vm.expectEmit();
        emit IProtocolGuardian.File("tokenBridge", newTokenBridge);

        vm.prank(address(SAFE));
        protocolGuardian.file("tokenBridge", newTokenBridge);

        assertEq(address(protocolGuardian.tokenBridge()), newTokenBridge);
    }

    function testFileRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IProtocolGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.file("safe", makeAddr("address"));
    }
}

contract ProtocolGuardianTestTokenBridge is ProtocolGuardianTest {
    function testFileRelayerSuccess() public {
        address relayer = makeAddr("relayer");

        vm.mockCall(
            address(tokenBridge),
            abi.encodeWithSignature("file(bytes32,address)", bytes32("relayer"), relayer),
            abi.encode()
        );
        vm.expectCall(
            address(tokenBridge), abi.encodeWithSignature("file(bytes32,address)", bytes32("relayer"), relayer)
        );

        vm.prank(address(SAFE));
        protocolGuardian.fileTokenBridgeRelayer(relayer);
    }

    function testFileRelayerRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IProtocolGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.fileTokenBridgeRelayer(makeAddr("relayer"));
    }
}
