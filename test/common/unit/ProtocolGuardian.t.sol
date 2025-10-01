// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {IProtocolGuardian, ISafe} from "../../../src/common/interfaces/IProtocolGuardian.sol";
import {IHubGuardianActions} from "../../../src/common/interfaces/IGuardianActions.sol";
import {IRoot} from "../../../src/common/interfaces/IRoot.sol";
import {IRootMessageSender} from "../../../src/common/interfaces/IGatewaySenders.sol";
import {ProtocolGuardian} from "../../../src/common/ProtocolGuardian.sol";
import "forge-std/Test.sol";

contract IsContract {}

contract ProtocolGuardianTest is Test {
    using CastLib for address;

    IRoot immutable root = IRoot(address(new IsContract()));
    ISafe immutable SAFE = ISafe(address(new IsContract()));
    IRootMessageSender immutable sender = IRootMessageSender(address(new IsContract()));
    IHubGuardianActions immutable hub = IHubGuardianActions(address(new IsContract()));

    address immutable OWNER = makeAddr("owner");
    address immutable UNAUTHORIZED = makeAddr("unauthorized");
    address immutable TARGET = makeAddr("target");
    address immutable TOKEN = makeAddr("token");
    address immutable TO = makeAddr("to");
    address immutable POOL_ADMIN = makeAddr("poolAdmin");
    address immutable REFUND = makeAddr("refund");

    uint16 constant CENTRIFUGE_ID = 1;
    uint256 constant TOKEN_ID = 1;
    uint256 constant AMOUNT = 100;
    uint256 constant COST = 123;
    PoolId constant POOL_A = PoolId.wrap(1);
    AssetId constant ASSET_ID_A = AssetId.wrap(1);

    ProtocolGuardian protocolGuardian;

    function setUp() public {
        protocolGuardian = new ProtocolGuardian(SAFE, root, sender);
        vm.deal(address(SAFE), 1 ether);
        vm.prank(address(SAFE));
        protocolGuardian.file("hub", address(hub));
    }

    function testProtocolGuardian() public view {
        assertEq(address(protocolGuardian.safe()), address(SAFE));
        assertEq(address(protocolGuardian.root()), address(root));
        assertEq(address(protocolGuardian.sender()), address(sender));
        assertEq(address(protocolGuardian.hub()), address(hub));
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
        vm.expectRevert(IProtocolGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.recoverTokens(CENTRIFUGE_ID, TARGET, TOKEN, TOKEN_ID, TO, AMOUNT, REFUND);
    }
}

contract ProtocolGuardianTestCreatePool is ProtocolGuardianTest {
    function testCreatePoolSuccess() public {
        vm.mockCall(
            address(hub), abi.encodeWithSelector(hub.createPool.selector, POOL_A, POOL_ADMIN, ASSET_ID_A), abi.encode()
        );
        vm.expectCall(address(hub), abi.encodeWithSelector(hub.createPool.selector, POOL_A, POOL_ADMIN, ASSET_ID_A));

        vm.prank(address(SAFE));
        protocolGuardian.createPool(POOL_A, POOL_ADMIN, ASSET_ID_A);
    }

    function testCreatePoolRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IProtocolGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.createPool(POOL_A, POOL_ADMIN, ASSET_ID_A);
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

    function testFileRevertWhenAdapterSpecificParam() public {
        // Protocol guardian should not accept adapter-specific params
        vm.prank(address(SAFE));
        vm.expectRevert(IProtocolGuardian.FileUnrecognizedParam.selector);
        protocolGuardian.file("gateway", makeAddr("address"));
    }

    function testFileRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IProtocolGuardian.NotTheAuthorizedSafe.selector);
        protocolGuardian.file("safe", makeAddr("address"));
    }
}