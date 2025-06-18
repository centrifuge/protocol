// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IGuardian} from "src/common/interfaces/IGuardian.sol";
import {IAxelarAdapter} from "src/common/interfaces/adapters/IAxelarAdapter.sol";
import {IWormholeAdapter} from "src/common/interfaces/adapters/IWormholeAdapter.sol";
import {Guardian, ISafe, IMultiAdapter, IRoot, IRootMessageSender} from "src/common/Guardian.sol";

import "forge-std/Test.sol";

contract GuardianTest is Test {
    Guardian guardian;
    ISafe immutable adminSafe = ISafe(makeAddr("adminSafe"));
    IMultiAdapter immutable gateway = IMultiAdapter(makeAddr("gateway"));
    IRoot immutable root = IRoot(makeAddr("root"));
    IRootMessageSender messageDispatcher = IRootMessageSender(makeAddr("messageDispatcher"));
    
    address immutable unauthorized = makeAddr("unauthorized");

    function setUp() public {
        guardian = new Guardian(adminSafe, gateway, root, messageDispatcher);
    }

    function testGuardian() public view {
        assertEq(address(guardian.safe()), address(adminSafe));
        assertEq(address(guardian.multiAdapter()), address(gateway));
        assertEq(address(guardian.root()), address(root));
        assertEq(address(guardian.sender()), address(messageDispatcher));
    }

    function testFile() public {
        vm.startPrank(address(adminSafe));

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
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.file("safe", makeAddr("newSafe"));
    }

    function testCreatePoolOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.createPool(PoolId.wrap(1), makeAddr("admin"), AssetId.wrap(1));
    }

    function testUnpauseOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.unpause();
    }

    function testScheduleRelyOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.scheduleRely(makeAddr("target"));
    }

    function testCancelRelyOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.cancelRely(makeAddr("target"));
    }

    function testScheduleUpgradeOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.scheduleUpgrade(1, makeAddr("target"));
    }

    function testCancelUpgradeOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.cancelUpgrade(1, makeAddr("target"));
    }

    function testRecoverTokensOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.recoverTokens(1, makeAddr("target"), makeAddr("token"), 0, makeAddr("to"), 100);
    }

    function testInitiateRecoveryOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.initiateRecovery(1, IAdapter(makeAddr("adapter")), bytes32(uint256(1)));
    }

    function testDisputeRecoveryOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.disputeRecovery(1, IAdapter(makeAddr("adapter")), bytes32(uint256(1)));
    }

    function testWireAdaptersOnlySafe() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = IAdapter(makeAddr("adapter"));
        
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.wireAdapters(1, adapters);
    }

    function testWireWormholeAdapterOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.wireWormholeAdapter(
            IWormholeAdapter(makeAddr("localAdapter")), 
            1, 
            2, 
            makeAddr("remoteAdapter")
        );
    }

    function testWireAxelarAdapterOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.wireAxelarAdapter(
            IAxelarAdapter(makeAddr("localAdapter")), 
            1, 
            "remoteAxelarId", 
            "remoteAdapterAddress"
        );
    }
}
