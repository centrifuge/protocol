// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {D18} from "../../src/misc/types/D18.sol";
import {IAuth} from "../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AssetId} from "../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {IGateway} from "../../src/core/messaging/interfaces/IGateway.sol";
import {MessageDispatcher} from "../../src/core/messaging/MessageDispatcher.sol";
import {VaultUpdateKind} from "../../src/core/messaging/libraries/MessageLib.sol";
import {IScheduleAuth} from "../../src/core/messaging/interfaces/IScheduleAuth.sol";
import {ISpokeMessageSender} from "../../src/core/messaging/interfaces/IGatewaySenders.sol";
import {IMessageDispatcher} from "../../src/core/messaging/interfaces/IMessageDispatcher.sol";

import "forge-std/Test.sol";

contract TestCommon is Test {
    uint16 constant LOCAL_CHAIN = 1;
    uint16 constant REMOTE_CHAIN = 2;
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16(uint128(2)));
    AssetId constant ASSET_A = AssetId.wrap(3);
    address immutable AUTH = makeAddr("auth");
    address immutable ANY = makeAddr("any");
    address immutable REFUND = makeAddr("refund");

    IGateway immutable gateway = IGateway(makeAddr("Gateway"));
    IScheduleAuth immutable scheduleAuth = IScheduleAuth(makeAddr("ScheduleAuth"));

    MessageDispatcher dispatcher;

    function setUp() external {
        dispatcher = new MessageDispatcher(LOCAL_CHAIN, scheduleAuth, gateway, AUTH);
        vm.deal(ANY, 1 ether);
    }
}

contract TestAuthChecks is TestCommon {
    function testErrNotAuthorized() public {
        vm.startPrank(ANY);

        bytes memory EMPTY_BYTES;
        ISpokeMessageSender.UpdateData memory EMPTY_DATA;

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendNotifyPool(REMOTE_CHAIN, POOL_A, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendNotifyShareClass(REMOTE_CHAIN, POOL_A, SC_A, "name", "SYM", 18, bytes32(0), bytes32(0), REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendNotifyShareMetadata(REMOTE_CHAIN, POOL_A, SC_A, "name", "SYM", REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendUpdateShareHook(REMOTE_CHAIN, POOL_A, SC_A, bytes32(0), REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendNotifyPricePoolPerShare(REMOTE_CHAIN, POOL_A, SC_A, D18.wrap(1e18), 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendNotifyPricePoolPerAsset(POOL_A, SC_A, ASSET_A, D18.wrap(1e18), REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendUpdateRestriction(REMOTE_CHAIN, POOL_A, SC_A, EMPTY_BYTES, 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendTrustedContractUpdate(REMOTE_CHAIN, POOL_A, SC_A, bytes32(0), EMPTY_BYTES, 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendUpdateVault(POOL_A, SC_A, ASSET_A, bytes32(0), VaultUpdateKind.DeployAndLink, 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendSetRequestManager(REMOTE_CHAIN, POOL_A, bytes32(0), REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendUpdateBalanceSheetManager(REMOTE_CHAIN, POOL_A, bytes32(0), true, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendSetMaxAssetPriceAge(POOL_A, SC_A, ASSET_A, 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendSetMaxSharePriceAge(REMOTE_CHAIN, POOL_A, SC_A, 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendScheduleUpgrade(REMOTE_CHAIN, bytes32(0), REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendCancelUpgrade(REMOTE_CHAIN, bytes32(0), REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendRecoverTokens(REMOTE_CHAIN, bytes32(0), bytes32(0), 0, bytes32(0), 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendInitiateTransferShares(REMOTE_CHAIN, POOL_A, SC_A, bytes32(0), 0, 0, 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendExecuteTransferShares(REMOTE_CHAIN, POOL_A, SC_A, bytes32(0), 0, 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendUpdateHoldingAmount(POOL_A, SC_A, ASSET_A, EMPTY_DATA, D18.wrap(1e18), 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendUpdateShares(POOL_A, SC_A, EMPTY_DATA, 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendRegisterAsset(REMOTE_CHAIN, ASSET_A, 18, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendRequest(POOL_A, SC_A, ASSET_A, EMPTY_BYTES, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendUntrustedContractUpdate(POOL_A, SC_A, bytes32(0), EMPTY_BYTES, bytes32(0), 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendRequestCallback(POOL_A, SC_A, ASSET_A, EMPTY_BYTES, 0, REFUND);

        bytes32[] memory adapters;
        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendSetPoolAdapters(REMOTE_CHAIN, POOL_A, adapters, 0, 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendUpdateGatewayManager(REMOTE_CHAIN, POOL_A, bytes32(0), true, REFUND);

        vm.stopPrank();
    }
}

contract TestFile is TestCommon {
    function testErrNotAuthorized() public {
        vm.prank(address(ANY));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.file("gateway", address(0));
    }

    function testErrFileUnrecognizedParam() public {
        vm.prank(address(AUTH));
        vm.expectRevert(IMessageDispatcher.FileUnrecognizedParam.selector);
        dispatcher.file("unknown", address(0));
    }

    function testFileGateway() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageDispatcher.File("gateway", address(23));
        dispatcher.file("gateway", address(23));
        assertEq(address(dispatcher.gateway()), address(23));
    }

    function testFileHubHandler() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageDispatcher.File("hubHandler", address(23));
        dispatcher.file("hubHandler", address(23));
        assertEq(address(dispatcher.hubHandler()), address(23));
    }

    function testFileSpoke() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageDispatcher.File("spoke", address(23));
        dispatcher.file("spoke", address(23));
        assertEq(address(dispatcher.spoke()), address(23));
    }

    function testFileBalanceSheet() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageDispatcher.File("balanceSheet", address(23));
        dispatcher.file("balanceSheet", address(23));
        assertEq(address(dispatcher.balanceSheet()), address(23));
    }

    function testFileVaultRegistry() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageDispatcher.File("vaultRegistry", address(23));
        dispatcher.file("vaultRegistry", address(23));
        assertEq(address(dispatcher.vaultRegistry()), address(23));
    }

    function testFileContractUpdater() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageDispatcher.File("contractUpdater", address(23));
        dispatcher.file("contractUpdater", address(23));
        assertEq(address(dispatcher.contractUpdater()), address(23));
    }

    function testFileTokenRecoverer() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageDispatcher.File("tokenRecoverer", address(23));
        dispatcher.file("tokenRecoverer", address(23));
        assertEq(address(dispatcher.tokenRecoverer()), address(23));
    }
}
