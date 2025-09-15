// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
import {IGuardian} from "../../../src/common/interfaces/IGuardian.sol";
import {IHubGuardianActions} from "../../../src/common/interfaces/IGuardianActions.sol";
import {Guardian, ISafe, IMultiAdapter, IRoot, IRootMessageSender} from "../../../src/common/Guardian.sol";

import "forge-std/Test.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract GuardianTest is Test {
    IRoot immutable root = IRoot(address(new IsContract()));
    IHubGuardianActions immutable hub = IHubGuardianActions(address(new IsContract()));
    IRootMessageSender sender = IRootMessageSender(address(new IsContract()));
    IMultiAdapter immutable multiAdapter = IMultiAdapter(makeAddr("multiAdapter"));

    ISafe immutable SAFE = ISafe(address(new IsContract()));
    address immutable OWNER = makeAddr("owner");
    address immutable UNAUTHORIZED = makeAddr("unauthorized");
    address immutable MANAGER = makeAddr("manager");

    uint16 constant CENTRIFUGE_ID = 1;
    PoolId constant POOL_0 = PoolId.wrap(0);
    PoolId constant POOL_A = PoolId.wrap(1);
    AssetId constant ASSET_ID_A = AssetId.wrap(1);
    address immutable TARGET = makeAddr("target");
    IAdapter immutable ADAPTER = IAdapter(makeAddr("adapter"));
    bytes32 immutable HASH = bytes32("hash");

    Guardian guardian = new Guardian(SAFE, multiAdapter, root, sender);

    function testGuardian() public view {
        assertEq(address(guardian.safe()), address(SAFE));
        assertEq(address(guardian.multiAdapter()), address(multiAdapter));
        assertEq(address(guardian.root()), address(root));
        assertEq(address(guardian.sender()), address(sender));
    }
}

contract GuardianTestFile is GuardianTest {
    function testFile() public {
        vm.startPrank(address(SAFE));

        guardian.file("sender", makeAddr("newSender"));
        assertEq(address(guardian.sender()), makeAddr("newSender"));

        guardian.file("hub", makeAddr("newHub"));
        assertEq(address(guardian.hub()), makeAddr("newHub"));

        guardian.file("multiAdapter", makeAddr("newMultiAdapter"));
        assertEq(address(guardian.multiAdapter()), makeAddr("newMultiAdapter"));

        guardian.file("safe", makeAddr("newSafe"));
        assertEq(address(guardian.safe()), makeAddr("newSafe"));
    }

    function testFileOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.file("safe", makeAddr("newSafe"));
    }
}

contract GuardianTestCreatePool is GuardianTest {
    address immutable POOL_ADMIN = makeAddr("poolAdmin");

    function testCreatePool() public {
        vm.prank(address(SAFE));
        guardian.file("hub", address(hub));

        vm.mockCall(
            address(hub), abi.encodeWithSelector(hub.createPool.selector, POOL_A, POOL_ADMIN, ASSET_ID_A), abi.encode()
        );

        vm.prank(address(SAFE));
        guardian.createPool(POOL_A, POOL_ADMIN, ASSET_ID_A);
    }

    function testCreatePoolOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.createPool(POOL_A, POOL_ADMIN, ASSET_ID_A);
    }
}

contract GuardianTestPause is GuardianTest {
    function testPause() public {
        vm.mockCall(address(root), abi.encodeWithSelector(root.pause.selector), abi.encode());

        vm.prank(address(SAFE));
        guardian.pause();
    }

    function testPauseWithOwner() public {
        vm.mockCall(address(root), abi.encodeWithSelector(root.pause.selector), abi.encode());
        vm.mockCall(address(SAFE), abi.encodeWithSelector(ISafe.isOwner.selector, OWNER), abi.encode(true));

        vm.prank(address(OWNER));
        guardian.pause();
    }

    function testPauseOnlySafe() public {
        vm.mockCall(address(SAFE), abi.encodeWithSelector(ISafe.isOwner.selector, UNAUTHORIZED), abi.encode(false));

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafeOrItsOwner.selector);
        guardian.pause();
    }
}

contract GuardianTestUnpause is GuardianTest {
    function testUnpause() public {
        vm.mockCall(address(root), abi.encodeWithSelector(root.unpause.selector), abi.encode());

        vm.prank(address(SAFE));
        guardian.unpause();
    }

    function testUnpauseOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.unpause();
    }
}

contract GuardianTestScheduleRely is GuardianTest {
    function testScheduleRely() public {
        vm.mockCall(address(root), abi.encodeWithSelector(root.scheduleRely.selector, TARGET), abi.encode());

        vm.prank(address(SAFE));
        guardian.scheduleRely(TARGET);
    }

    function testScheduleRelyOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.scheduleRely(TARGET);
    }
}

contract GuardianTestCancelRely is GuardianTest {
    function testCancelRely() public {
        vm.mockCall(address(root), abi.encodeWithSelector(root.cancelRely.selector, TARGET), abi.encode());

        vm.prank(address(SAFE));
        guardian.cancelRely(TARGET);
    }

    function testCancelRelyOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.cancelRely(TARGET);
    }
}

contract GuardianTestScheduleUpgrade is GuardianTest {
    using CastLib for *;

    function testScheduleUpgrade() public {
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(sender.sendScheduleUpgrade.selector, CENTRIFUGE_ID, TARGET.toBytes32()),
            abi.encode()
        );

        vm.prank(address(SAFE));
        guardian.scheduleUpgrade(CENTRIFUGE_ID, TARGET);
    }

    function testScheduleUpgradeOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.scheduleUpgrade(CENTRIFUGE_ID, TARGET);
    }
}

contract GuardianTestCancelUpgrade is GuardianTest {
    using CastLib for *;

    function testCancelUpgrade() public {
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(sender.sendCancelUpgrade.selector, CENTRIFUGE_ID, TARGET.toBytes32()),
            abi.encode()
        );

        vm.prank(address(SAFE));
        guardian.cancelUpgrade(CENTRIFUGE_ID, TARGET);
    }

    function testCancelUpgradeOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.cancelUpgrade(CENTRIFUGE_ID, TARGET);
    }
}

contract GuardianTestRecoverTokens is GuardianTest {
    using CastLib for *;

    address immutable TOKEN = makeAddr("Token");
    uint256 constant TOKEN_ID = 1;
    address immutable TO = makeAddr("To");
    uint256 constant AMOUNT = 100;

    function testRecoverTokens() public {
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(
                sender.sendRecoverTokens.selector,
                CENTRIFUGE_ID,
                TARGET.toBytes32(),
                TOKEN.toBytes32(),
                TOKEN_ID,
                TO.toBytes32(),
                AMOUNT
            ),
            abi.encode()
        );

        vm.prank(address(SAFE));
        guardian.recoverTokens(CENTRIFUGE_ID, TARGET, TOKEN, TOKEN_ID, TO, AMOUNT);
    }

    function testRecoverTokensOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.recoverTokens(CENTRIFUGE_ID, TARGET, TOKEN, TOKEN_ID, TO, AMOUNT);
    }
}

contract GuardianTestSetAdapters is GuardianTest {
    function testSetAdapters() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;

        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.setAdapters.selector, CENTRIFUGE_ID, POOL_0, adapters, 1, 2),
            abi.encode()
        );

        vm.prank(address(SAFE));
        guardian.setAdapters(CENTRIFUGE_ID, adapters, 1, 2);
    }

    function testSetAdaptersOnlySafe() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.setAdapters(CENTRIFUGE_ID, adapters, 1, 2);
    }
}

contract GuardianTestSetGatewayManagers is GuardianTest {
    function testSetAdaptersManagers() public {
        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.setManager.selector, POOL_0, MANAGER),
            abi.encode()
        );

        vm.prank(address(SAFE));
        guardian.setGatewayManager(MANAGER);
    }

    function testSetAdaptersOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.setGatewayManager(MANAGER);
    }
}
