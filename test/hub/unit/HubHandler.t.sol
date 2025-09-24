// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {D18} from "../../../src/misc/types/D18.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";

import {IHub} from "../../../src/hub/interfaces/IHub.sol";
import {HubHandler} from "../../../src/hub/HubHandler.sol";
import {IHoldings} from "../../../src/hub/interfaces/IHoldings.sol";
import {IHubHandler} from "../../../src/hub/interfaces/IHubHandler.sol";
import {JournalEntry} from "../../../src/hub/interfaces/IAccounting.sol";
import {IHubRegistry} from "../../../src/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "../../../src/hub/interfaces/IShareClassManager.sol";

import "forge-std/Test.sol";

contract TestCommon is Test {
    uint16 constant CHAIN_A = 23;
    uint16 constant CHAIN_B = 24;
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16(uint128(2)));
    AssetId constant ASSET_A = AssetId.wrap(3);
    address constant ADMIN = address(1);
    JournalEntry[] EMPTY;
    address immutable AUTH = makeAddr("auth");
    address immutable ANY = makeAddr("any");

    IHubRegistry immutable hubRegistry = IHubRegistry(makeAddr("HubRegistry"));
    IHub immutable hub = IHub(makeAddr("Hub"));
    IHoldings immutable holdings = IHoldings(makeAddr("Holdings"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));

    HubHandler hubHandler = new HubHandler(hub, holdings, hubRegistry, scm, AUTH);
}

contract TestMainMethodsChecks is TestCommon {
    function testErrNotAuthotized() public {
        vm.startPrank(makeAddr("noGateway"));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHandler.registerAsset(AssetId.wrap(0), 0);

        bytes memory EMPTY_BYTES;
        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHandler.request(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), EMPTY_BYTES);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHandler.updateHoldingAmount(
            CHAIN_A, PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), 0, D18.wrap(1), false, true, 0
        );

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHandler.updateShares(CHAIN_A, PoolId.wrap(0), ShareClassId.wrap(0), 0, true, true, 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHandler.initiateTransferShares(CHAIN_A, CHAIN_B, PoolId.wrap(0), ShareClassId.wrap(0), bytes32(""), 0, 0);

        vm.stopPrank();
    }
}

contract TestFile is TestCommon {
    function testErrNotAuthorized() public {
        vm.prank(address(ANY));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHandler.file("hub", address(0));
    }

    function testErrFileUnrecognizedParam() public {
        vm.prank(address(AUTH));
        vm.expectRevert(IHubHandler.FileUnrecognizedParam.selector);
        hubHandler.file("unknown", address(0));
    }

    function testFileHub() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IHubHandler.File("hub", address(23));
        hubHandler.file("hub", address(23));
        assertEq(address(hubHandler.hub()), address(23));
    }

    function testFileHoldings() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IHubHandler.File("holdings", address(23));
        hubHandler.file("holdings", address(23));
        assertEq(address(hubHandler.holdings()), address(23));
    }

    function testFileSender() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IHubHandler.File("sender", address(23));
        hubHandler.file("sender", address(23));
        assertEq(address(hubHandler.sender()), address(23));
    }

    function testFileShareClassmanager() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IHubHandler.File("shareClassManager", address(23));
        hubHandler.file("shareClassManager", address(23));
        assertEq(address(hubHandler.shareClassManager()), address(23));
    }
}
