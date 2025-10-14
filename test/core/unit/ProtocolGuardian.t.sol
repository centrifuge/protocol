// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IGateway} from "../../../src/core/messaging/interfaces/IGateway.sol";
import {IMultiAdapter} from "../../../src/core/messaging/interfaces/IMultiAdapter.sol";
import {IScheduleAuthMessageSender} from "../../../src/core/messaging/interfaces/IGatewaySenders.sol";

import {IRoot} from "../../../src/admin/interfaces/IRoot.sol";
import {ISafe} from "../../../src/admin/interfaces/ISafe.sol";
import {ProtocolGuardian} from "../../../src/admin/ProtocolGuardian.sol";
import {IBaseGuardian} from "../../../src/admin/interfaces/IBaseGuardian.sol";
import {IAdapterWiring} from "../../../src/admin/interfaces/IAdapterWiring.sol";
import {IProtocolGuardian} from "../../../src/admin/interfaces/IProtocolGuardian.sol";

import "forge-std/Test.sol";

contract IsContract {}

contract ProtocolGuardianTest is Test {
    using CastLib for address;

    IRoot immutable root = IRoot(address(new IsContract()));
    ISafe immutable SAFE = ISafe(address(new IsContract()));
    IGateway immutable gateway = IGateway(address(new IsContract()));
    IMultiAdapter immutable multiAdapter = IMultiAdapter(address(new IsContract()));
    IScheduleAuthMessageSender immutable sender = IScheduleAuthMessageSender(address(new IsContract()));

    address immutable OWNER = makeAddr("owner");
    address immutable UNAUTHORIZED = makeAddr("unauthorized");
    address immutable TARGET = makeAddr("target");
    address immutable TOKEN = makeAddr("token");
    address immutable TO = makeAddr("to");
    address immutable REFUND = makeAddr("refund");
    IAdapter immutable ADAPTER = IAdapter(makeAddr("adapter"));

    uint16 constant CENTRIFUGE_ID = 1;
    uint256 constant TOKEN_ID = 1;
    uint256 constant AMOUNT = 100;
    uint256 constant COST = 123;
    PoolId constant GLOBAL_POOL = PoolId.wrap(0);

    ProtocolGuardian protocolGuardian;

    function setUp() public {
        protocolGuardian = new ProtocolGuardian(SAFE, root, gateway, multiAdapter, sender);
        vm.deal(address(SAFE), 1 ether);
    }

    function testProtocolGuardian() public view {
        assertEq(address(protocolGuardian.safe()), address(SAFE));
        assertEq(address(protocolGuardian.root()), address(root));
        assertEq(address(protocolGuardian.gateway()), address(gateway));
        assertEq(address(protocolGuardian.multiAdapter()), address(multiAdapter));
        assertEq(address(protocolGuardian.sender()), address(sender));
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
        vm.expectRevert(IBaseGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.unpause();
    }

    function testUnpauseRevertWhenOwner() public {
        vm.prank(OWNER);
        vm.expectRevert(IBaseGuardian.NotTheAuthorizedSafe.selector);
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
        vm.expectRevert(IBaseGuardian.NotTheAuthorizedSafe.selector);
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
        vm.expectRevert(IBaseGuardian.NotTheAuthorizedSafe.selector);
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
        vm.expectRevert(IBaseGuardian.NotTheAuthorizedSafe.selector);
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
        vm.expectRevert(IBaseGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.cancelUpgrade(CENTRIFUGE_ID, TARGET, REFUND);
    }
}

contract ProtocolGuardianTestRecoverTokens is ProtocolGuardianTest {
    using CastLib for address;

    function testRecoverTokensSuccess() public {
        vm.mockCall(
            address(sender),
            COST,
            abi.encodeWithSelector(
                sender.sendRecoverTokens.selector,
                CENTRIFUGE_ID,
                TARGET.toBytes32(),
                TOKEN.toBytes32(),
                TOKEN_ID,
                TO.toBytes32(),
                AMOUNT,
                REFUND
            ),
            abi.encode()
        );

        vm.prank(address(SAFE));
        protocolGuardian.recoverTokens{value: COST}(CENTRIFUGE_ID, TARGET, TOKEN, TOKEN_ID, TO, AMOUNT, REFUND);
    }

    function testRecoverTokensRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IBaseGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.recoverTokens(CENTRIFUGE_ID, TARGET, TOKEN, TOKEN_ID, TO, AMOUNT, REFUND);
    }
}

contract ProtocolGuardianTestSetAdapters is ProtocolGuardianTest {
    function testSetAdaptersSuccess() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;
        uint8 threshold = 1;
        uint8 recoveryIndex = 2;

        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(
                IMultiAdapter.setAdapters.selector, CENTRIFUGE_ID, GLOBAL_POOL, adapters, threshold, recoveryIndex
            ),
            abi.encode()
        );

        vm.expectCall(
            address(multiAdapter),
            abi.encodeWithSelector(
                IMultiAdapter.setAdapters.selector, CENTRIFUGE_ID, GLOBAL_POOL, adapters, threshold, recoveryIndex
            )
        );

        vm.prank(address(SAFE));
        protocolGuardian.setAdapters(CENTRIFUGE_ID, adapters, threshold, recoveryIndex);
    }

    function testSetAdaptersRevertWhenNotSafe() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IBaseGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.setAdapters(CENTRIFUGE_ID, adapters, 1, 2);
    }
}

contract ProtocolGuardianTestBlockOutgoing is ProtocolGuardianTest {
    function testBlockOutgoingBlockSuccess() public {
        vm.mockCall(
            address(gateway),
            abi.encodeWithSelector(IGateway.blockOutgoing.selector, CENTRIFUGE_ID, GLOBAL_POOL, true),
            abi.encode()
        );
        vm.expectCall(
            address(gateway), abi.encodeWithSelector(IGateway.blockOutgoing.selector, CENTRIFUGE_ID, GLOBAL_POOL, true)
        );

        vm.prank(address(SAFE));
        protocolGuardian.blockOutgoing(CENTRIFUGE_ID, true);
    }

    function testBlockOutgoingUnblockSuccess() public {
        vm.mockCall(
            address(gateway),
            abi.encodeWithSelector(IGateway.blockOutgoing.selector, CENTRIFUGE_ID, GLOBAL_POOL, false),
            abi.encode()
        );
        vm.expectCall(
            address(gateway), abi.encodeWithSelector(IGateway.blockOutgoing.selector, CENTRIFUGE_ID, GLOBAL_POOL, false)
        );

        vm.prank(address(SAFE));
        protocolGuardian.blockOutgoing(CENTRIFUGE_ID, false);
    }

    function testBlockOutgoingRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IBaseGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.blockOutgoing(CENTRIFUGE_ID, true);
    }
}

contract ProtocolGuardianTestFile is ProtocolGuardianTest {
    function testFileSafeSuccess() public {
        address newSafe = makeAddr("newSafe");

        vm.expectEmit();
        emit IBaseGuardian.File("safe", newSafe);

        vm.prank(address(SAFE));
        protocolGuardian.file("safe", newSafe);

        assertEq(address(protocolGuardian.safe()), newSafe);
    }

    function testFileSenderSuccess() public {
        address newSender = makeAddr("newSender");

        vm.expectEmit();
        emit IBaseGuardian.File("sender", newSender);

        vm.prank(address(SAFE));
        protocolGuardian.file("sender", newSender);

        assertEq(address(protocolGuardian.sender()), newSender);
    }

    function testFileRevertWhenUnrecognizedParam() public {
        vm.prank(address(SAFE));
        vm.expectRevert(IBaseGuardian.FileUnrecognizedParam.selector);
        protocolGuardian.file("invalid", makeAddr("address"));
    }

    function testFileGatewaySuccess() public {
        address newGateway = makeAddr("newGateway");

        vm.expectEmit();
        emit IBaseGuardian.File("gateway", newGateway);

        vm.prank(address(SAFE));
        protocolGuardian.file("gateway", newGateway);

        assertEq(address(protocolGuardian.gateway()), newGateway);
    }

    function testFileMultiAdapterSuccess() public {
        address newMultiAdapter = makeAddr("newMultiAdapter");

        vm.expectEmit();
        emit IBaseGuardian.File("multiAdapter", newMultiAdapter);

        vm.prank(address(SAFE));
        protocolGuardian.file("multiAdapter", newMultiAdapter);

        assertEq(address(protocolGuardian.multiAdapter()), newMultiAdapter);
    }

    function testFileRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IBaseGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.file("safe", makeAddr("address"));
    }
}

contract ProtocolGuardianTestWire is ProtocolGuardianTest {
    function testWireSuccess() public {
        bytes memory data = abi.encode("some", "data");

        vm.mockCall(
            address(ADAPTER), abi.encodeWithSelector(IAdapterWiring.wire.selector, CENTRIFUGE_ID, data), abi.encode()
        );

        vm.expectCall(address(ADAPTER), abi.encodeWithSelector(IAdapterWiring.wire.selector, CENTRIFUGE_ID, data));

        vm.prank(address(SAFE));
        protocolGuardian.wire(address(ADAPTER), CENTRIFUGE_ID, data);
    }

    function testWireRevertWhenNotSafe() public {
        bytes memory data = abi.encode("some", "data");

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IBaseGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.wire(address(ADAPTER), CENTRIFUGE_ID, data);
    }
}
