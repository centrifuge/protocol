// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {D18} from "../../src/misc/types/D18.sol";
import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {SafeTransferLib} from "../../src/misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AssetId} from "../../src/core/types/AssetId.sol";
import {IEnvoy} from "../../src/core/utils/interfaces/IEnvoy.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {IGateway} from "../../src/core/messaging/interfaces/IGateway.sol";
import {MessageDispatcher} from "../../src/core/messaging/MessageDispatcher.sol";
import {IScheduleAuth} from "../../src/core/messaging/interfaces/IScheduleAuth.sol";
import {IMessageDispatcher} from "../../src/core/messaging/interfaces/IMessageDispatcher.sol";
import {ISpokeGatewayHandler} from "../../src/core/messaging/interfaces/IGatewayHandlers.sol";
import {VaultUpdateKind, ManagerKind} from "../../src/core/messaging/libraries/MessageLib.sol";
import {ISpokeMessageSender, ShareClassMetadata} from "../../src/core/messaging/interfaces/IGatewaySenders.sol";

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
        dispatcher.sendNotifyShareClass(
            REMOTE_CHAIN,
            POOL_A,
            SC_A,
            ShareClassMetadata("name", "SYM", 18),
            bytes32(0),
            bytes32(0),
            EMPTY_BYTES,
            0,
            REFUND
        );

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendNotifyShareMetadata(REMOTE_CHAIN, POOL_A, SC_A, "name", "SYM", 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendNotifyPricePoolPerShare(REMOTE_CHAIN, POOL_A, SC_A, D18.wrap(1e18), 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendNotifyPricePoolPerAsset(POOL_A, SC_A, ASSET_A, D18.wrap(1e18), REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendUpdateRestriction(REMOTE_CHAIN, POOL_A, SC_A, EMPTY_BYTES, 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendManagerCallFromHub(LOCAL_CHAIN, POOL_A, makeAddr("target"), EMPTY_BYTES, 0, 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendUpdateVault(
            POOL_A, SC_A, ASSET_A, bytes32(0), VaultUpdateKind.DeployAndLink, bytes(""), 0, REFUND
        );

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendSetRequestManager(REMOTE_CHAIN, POOL_A, bytes32(0), REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendUpdateManager(REMOTE_CHAIN, POOL_A, ManagerKind.Spoke, bytes32(0), true, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendScheduleUpgrade(REMOTE_CHAIN, bytes32(0), REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendCancelUpgrade(REMOTE_CHAIN, bytes32(0), REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendInitiateTransferShares(REMOTE_CHAIN, POOL_A, SC_A, bytes32(0), bytes32(0), 0, 0, 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendExecuteTransferShares(LOCAL_CHAIN, REMOTE_CHAIN, POOL_A, SC_A, bytes32(0), 0, 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendUpdateHoldingAmount(POOL_A, SC_A, ASSET_A, EMPTY_DATA, D18.wrap(1e18), 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendUpdateShares(POOL_A, SC_A, EMPTY_DATA, 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendRegisterAsset(REMOTE_CHAIN, ASSET_A, 18, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendRequest(POOL_A, SC_A, ASSET_A, EMPTY_BYTES, 0, false, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendManagerCallFromSpoke(POOL_A, bytes32(0), EMPTY_BYTES, bytes32(0), 0, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendRequestCallback(POOL_A, SC_A, ASSET_A, EMPTY_BYTES, 0, false, REFUND);

        bytes32[] memory adapters;
        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendSetPoolAdapters(REMOTE_CHAIN, POOL_A, adapters, 0, 1, REFUND);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.sendUpdateManager(REMOTE_CHAIN, POOL_A, ManagerKind.Adapter, bytes32(0), true, REFUND);

        vm.stopPrank();
    }
}

contract TestSendManagerCall is TestCommon {
    address immutable mcDispatcher = makeAddr("envoy");
    address immutable target = makeAddr("managerCallTarget");

    function testLocalBranchForwardsFullValue() public {
        vm.prank(AUTH);
        dispatcher.file("envoy", mcDispatcher);

        bytes memory payload = hex"1234";
        // The hub direction carries no origin args (already authorized at the Hub).
        // `Hub.managerCall` guarantees `value == msg.value` on the local branch, so the whole balance is
        // forwarded to `callFromHub` and the dispatcher keeps no remainder.
        bytes memory expectedCall = abi.encodeWithSelector(IEnvoy.callFromHub.selector, POOL_A, target, payload);
        vm.mockCall(mcDispatcher, expectedCall, "");
        vm.expectCall(mcDispatcher, 0.5 ether, expectedCall);

        vm.deal(AUTH, 1 ether);
        vm.prank(AUTH);
        dispatcher.sendManagerCallFromHub{value: 0.5 ether}(LOCAL_CHAIN, POOL_A, target, payload, 0, 0.5 ether, REFUND);

        assertEq(REFUND.balance, 0, "no refund leg");
    }

    function testRemoteBranchSendsManagerCall() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(IGateway.send.selector), "");
        vm.expectCall(address(gateway), abi.encodeWithSelector(IGateway.send.selector));

        vm.prank(AUTH);
        dispatcher.sendManagerCallFromHub(REMOTE_CHAIN, POOL_A, target, hex"1234", 0, 0, REFUND);
    }

    function testLocalBranchRefundsExcessValue() public {
        vm.prank(AUTH);
        dispatcher.file("envoy", mcDispatcher);

        bytes memory payload = hex"1234";
        vm.mockCall(mcDispatcher, abi.encodeWithSelector(IEnvoy.callFromHub.selector, POOL_A, target, payload), "");

        vm.deal(AUTH, 1 ether);
        vm.prank(AUTH);
        dispatcher.sendManagerCallFromHub{value: 1 ether}(LOCAL_CHAIN, POOL_A, target, payload, 0, 0.5 ether, REFUND);

        assertEq(REFUND.balance, 0.5 ether, "excess value refunded");
    }

    function testLocalBranchRevertsIfRefundFails() public {
        vm.prank(AUTH);
        dispatcher.file("envoy", mcDispatcher);

        bytes memory payload = hex"1234";
        vm.mockCall(mcDispatcher, abi.encodeWithSelector(IEnvoy.callFromHub.selector, POOL_A, target, payload), "");

        address rejectingRefund = address(new RejectsAllETH());
        vm.deal(AUTH, 1 ether);
        vm.prank(AUTH);
        vm.expectRevert(SafeTransferLib.SafeTransferEthFailed.selector);
        dispatcher.sendManagerCallFromHub{value: 1 ether}(
            LOCAL_CHAIN, POOL_A, target, payload, 0, 0.5 ether, rejectingRefund
        );
    }
}

/// @dev Rejects any ETH sent to it, even a zero-value call.
contract RejectsAllETH {
    fallback() external payable {
        revert("always reverts");
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

    function testFileSpokeHandler() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageDispatcher.File("spokeHandler", address(23));
        dispatcher.file("spokeHandler", address(23));
        assertEq(address(dispatcher.spokeHandler()), address(23));
    }

    function testFileEnvoy() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageDispatcher.File("envoy", address(23));
        dispatcher.file("envoy", address(23));
        assertEq(address(dispatcher.envoy()), address(23));
    }
}

contract TestSendUpdateManagerLocal is TestCommon {
    address immutable spokeHandler = makeAddr("spokeHandler");
    address immutable who = makeAddr("who");

    function testLocalGatewayBranch() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(IGateway.updateManager.selector), "");
        vm.expectCall(address(gateway), abi.encodeWithSelector(IGateway.updateManager.selector, POOL_A, who, true));

        vm.prank(AUTH);
        dispatcher.sendUpdateManager(LOCAL_CHAIN, POOL_A, ManagerKind.Gateway, bytes32(bytes20(who)), true, REFUND);
    }

    function testLocalBridgerBranch() public {
        vm.prank(AUTH);
        dispatcher.file("spokeHandler", spokeHandler);

        vm.mockCall(spokeHandler, abi.encodeWithSelector(ISpokeGatewayHandler.updateBridger.selector), "");
        vm.expectCall(
            spokeHandler, abi.encodeWithSelector(ISpokeGatewayHandler.updateBridger.selector, POOL_A, who, true)
        );

        vm.prank(AUTH);
        dispatcher.sendUpdateManager(LOCAL_CHAIN, POOL_A, ManagerKind.Bridger, bytes32(bytes20(who)), true, REFUND);
    }
}
