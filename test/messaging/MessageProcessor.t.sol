// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";

import {newAssetId} from "../../src/core/types/AssetId.sol";
import {PoolId, newPoolId} from "../../src/core/types/PoolId.sol";
import {IGateway} from "../../src/core/messaging/interfaces/IGateway.sol";
import {MessageProcessor} from "../../src/core/messaging/MessageProcessor.sol";
import {IMultiAdapter} from "../../src/core/messaging/interfaces/IMultiAdapter.sol";
import {IScheduleAuth} from "../../src/core/messaging/interfaces/IScheduleAuth.sol";
import {MessageLib, ManagerKind} from "../../src/core/messaging/libraries/MessageLib.sol";
import {IMessageProcessor} from "../../src/core/messaging/interfaces/IMessageProcessor.sol";
import {ISpokeGatewayHandler} from "../../src/core/messaging/interfaces/IGatewayHandlers.sol";

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

/// @dev Source-chain classification now lives entirely in MessageLib.messageSourceCentrifugeId, enforced
///      by Gateway before a message ever reaches MessageProcessor (see Gateway.t.sol for the enforcement
///      tests). This checks that classification against real, `serialize()`d messages of every type -
///      MessageLib.t.sol's exhaustive test covers the same logic against a synthetic buffer, so this
///      additionally guards against a mismatch between the two encodings.
contract TestMessageSourceClassification is Test {
    using MessageLib for *;

    uint16 constant HOME_CHAIN = 1;
    uint16 constant FOREIGN_CHAIN = 2;

    /// @param name        Message type name, surfaced when a row fails.
    /// @param message     A valid serialized message of that type.
    /// @param validSource Chain the message is legitimately accepted from, or 0 if unrestricted.
    struct Case {
        string name;
        bytes message;
        uint16 validSource;
    }

    PoolId poolId = newPoolId(HOME_CHAIN, 42);

    /// @dev One row per pool-dependent message type (plus SetPoolAdapters, the only Hub->spoke message
    ///      ordered before NotifyPool).
    function _cases() internal view returns (Case[] memory cases) {
        uint64 p = poolId.raw();

        cases = new Case[](20);

        // Hub->spoke: only valid coming from the pool's home chain.
        cases[0] = Case(
            "SetPoolAdapters",
            MessageLib.SetPoolAdapters({poolId: p, threshold: 0, targetSessionId: 1, adapterList: new bytes32[](0)})
                .serialize(),
            HOME_CHAIN
        );
        cases[1] = Case("NotifyPool", MessageLib.NotifyPool({poolId: p}).serialize(), HOME_CHAIN);
        cases[2] = Case(
            "NotifyShareClass",
            MessageLib.NotifyShareClass({
                    poolId: p,
                    scId: bytes16("sc"),
                    name: "name",
                    symbol: bytes32("SYM"),
                    decimals: 6,
                    salt: bytes32("salt"),
                    registrar: bytes32("registrar"),
                    extraGasLimit: 0,
                    payload: ""
                }).serialize(),
            HOME_CHAIN
        );
        cases[3] = Case(
            "NotifyPricePoolPerShare",
            MessageLib.NotifyPricePoolPerShare({poolId: p, scId: bytes16("sc"), price: 1, timestamp: 0}).serialize(),
            HOME_CHAIN
        );
        cases[4] = Case(
            "NotifyPricePoolPerAsset",
            MessageLib.NotifyPricePoolPerAsset({poolId: p, scId: bytes16("sc"), assetId: 1, price: 1, timestamp: 0})
                .serialize(),
            HOME_CHAIN
        );
        cases[5] = Case(
            "NotifyShareMetadata",
            MessageLib.NotifyShareMetadata({
                    poolId: p, scId: bytes16("sc"), name: "name", symbol: bytes32("SYM"), extraGasLimit: 0
                }).serialize(),
            HOME_CHAIN
        );
        cases[6] = Case(
            "ExecuteTransferShares",
            MessageLib.ExecuteTransferShares({
                    poolId: p, scId: bytes16("sc"), receiver: bytes32("receiver"), amount: 1, extraGasLimit: 0
                }).serialize(),
            HOME_CHAIN
        );
        cases[7] = Case(
            "UpdateRestriction",
            MessageLib.UpdateRestriction({poolId: p, scId: bytes16("sc"), extraGasLimit: 0, payload: bytes("")})
                .serialize(),
            HOME_CHAIN
        );
        cases[8] = Case(
            "UpdateVault",
            MessageLib.UpdateVault({
                    poolId: p,
                    scId: bytes16("sc"),
                    assetId: 1,
                    vaultOrFactory: bytes32("vault"),
                    kind: 0,
                    extraGasLimit: 0,
                    payload: bytes("")
                }).serialize(),
            HOME_CHAIN
        );
        cases[9] = Case(
            "RequestCallback",
            MessageLib.RequestCallback({
                    poolId: p, scId: bytes16("sc"), assetId: 1, extraGasLimit: 0, payload: bytes("")
                }).serialize(),
            HOME_CHAIN
        );
        cases[10] = Case(
            "SetRequestManager",
            MessageLib.SetRequestManager({poolId: p, manager: bytes32("manager")}).serialize(),
            HOME_CHAIN
        );
        cases[11] = Case(
            "ManagerCall",
            MessageLib.ManagerCallFromHub({poolId: p, target: bytes32("target"), extraGasLimit: 0, payload: bytes("")})
                .serialize(),
            HOME_CHAIN
        );
        cases[12] = Case(
            "UpdateManager",
            MessageLib.UpdateManager({
                    poolId: p, kind: uint8(ManagerKind.Adapter), who: bytes32("manager"), canManage: true
                }).serialize(),
            HOME_CHAIN
        );

        // Spoke->hub (the exclusion list in messageSourceCentrifugeId): unrestricted (0), except
        // UpdateHoldingAmount/Request which carry their own asset-origin check.
        cases[13] = Case(
            "InitiateTransferShares",
            MessageLib.InitiateTransferShares({
                    poolId: p,
                    scId: bytes16("sc"),
                    centrifugeId: HOME_CHAIN,
                    receiver: bytes32("receiver"),
                    amount: 1,
                    remoteExtraGasLimit: 0,
                    extraGasLimit: 0,
                    sender: bytes32("sender")
                }).serialize(),
            0
        );
        cases[14] = Case(
            "UpdateHoldingAmount",
            MessageLib.UpdateAssets({
                    poolId: p,
                    scId: bytes16("sc"),
                    assetId: newAssetId(FOREIGN_CHAIN, 0).raw(),
                    amount: 1,
                    timestamp: 0,
                    isIncrease: true,
                    isSnapshot: false,
                    nonce: 0,
                    extraGasLimit: 0
                }).serialize(),
            FOREIGN_CHAIN
        );
        cases[15] = Case(
            "UpdateShares",
            MessageLib.UpdateShares({
                    poolId: p,
                    scId: bytes16("sc"),
                    shares: 1,
                    timestamp: 0,
                    isIssuance: true,
                    isSnapshot: false,
                    nonce: 0,
                    extraGasLimit: 0
                }).serialize(),
            0
        );
        cases[16] = Case(
            "Request",
            MessageLib.Request({
                    poolId: p,
                    scId: bytes16("sc"),
                    assetId: newAssetId(FOREIGN_CHAIN, 0).raw(),
                    extraGasLimit: 0,
                    payload: bytes("")
                }).serialize(),
            FOREIGN_CHAIN
        );
        cases[17] = Case(
            "ManagerCallFromSpoke",
            MessageLib.ManagerCallFromSpoke({
                    poolId: p,
                    target: bytes32("target"),
                    sender: bytes32("sender"),
                    extraGasLimit: 0,
                    payload: bytes("")
                }).serialize(),
            0
        );

        // Mainnet-only messages: must come from centrifugeId=1.
        cases[18] = Case(
            "ScheduleUpgrade",
            MessageLib.ScheduleUpgrade({target: bytes32(bytes20(address(1)))}).serialize(),
            HOME_CHAIN
        );
        cases[19] = Case(
            "CancelUpgrade", MessageLib.CancelUpgrade({target: bytes32(bytes20(address(1)))}).serialize(), HOME_CHAIN
        );
    }

    function testMessageSourceCentrifugeIdPerMessageType() public view {
        Case[] memory cases = _cases();

        for (uint256 i; i < cases.length; i++) {
            Case memory c = cases[i];
            assertEq(c.message.messageSourceCentrifugeId(), c.validSource, c.name);
        }
    }
}

contract TestFile is TestCommon {
    function testErrNotAuthorized() public {
        vm.prank(address(ANY));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        processor.file("multiAdapter", address(0));
    }

    function testErrFileUnrecognizedParam() public {
        vm.prank(address(AUTH));
        vm.expectRevert(IMessageProcessor.FileUnrecognizedParam.selector);
        processor.file("unknown", address(0));
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

    function testFileGateway() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("gateway", address(23));
        processor.file("gateway", address(23));
        assertEq(address(processor.gateway()), address(23));
    }

    function testFileSpokeHandler() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("spokeHandler", address(23));
        processor.file("spokeHandler", address(23));
        assertEq(address(processor.spokeHandler()), address(23));
    }

    function testFileEnvoy() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("envoy", address(23));
        processor.file("envoy", address(23));
        assertEq(address(processor.envoy()), address(23));
    }
}

/// @dev Source/self-origin classification now lives in Gateway, enforced before a message ever reaches
///      MessageProcessor - see Gateway.t.sol. This only checks MessageProcessor's own dispatch to
///      MultiAdapter.setAdapters.
contract TestHandleSetPoolAdapters is TestCommon {
    using MessageLib for *;

    uint16 constant HUB_ID = 1;
    address multiAdapter = makeAddr("multiAdapter");
    PoolId poolId = newPoolId(HUB_ID, 1);

    function _message() internal returns (bytes memory) {
        bytes32[] memory adapters = new bytes32[](1);
        adapters[0] = bytes32(bytes20(makeAddr("adapter")));
        return MessageLib.SetPoolAdapters({
                poolId: poolId.raw(), threshold: 1, targetSessionId: 1, adapterList: adapters
            }).serialize();
    }

    function testDispatchesToMultiAdapter() public {
        vm.prank(AUTH);
        processor.file("multiAdapter", multiAdapter);

        vm.mockCall(multiAdapter, abi.encodeWithSelector(IMultiAdapter.setAdapters.selector), "");

        vm.expectCall(multiAdapter, abi.encodeWithSelector(IMultiAdapter.setAdapters.selector));
        vm.prank(AUTH);
        processor.handle(HUB_ID, _message());
    }
}

contract TestHandleUpdateManager is TestCommon {
    using MessageLib for *;

    uint16 constant HUB_ID = 1;
    address multiAdapter = makeAddr("multiAdapter");
    address gateway = makeAddr("gateway");
    address spokeHandler = makeAddr("spokeHandler");
    PoolId poolId = newPoolId(HUB_ID, 1);
    address who = makeAddr("who");

    function _wireTargets() internal {
        vm.startPrank(AUTH);
        processor.file("multiAdapter", multiAdapter);
        processor.file("gateway", gateway);
        processor.file("spokeHandler", spokeHandler);
        vm.stopPrank();
    }

    function _message(ManagerKind kind) internal view returns (bytes memory) {
        return MessageLib.UpdateManager({
                poolId: poolId.raw(), kind: uint8(kind), who: bytes32(bytes20(who)), canManage: true
            }).serialize();
    }

    function testDispatchesToMultiAdapter() public {
        _wireTargets();
        vm.mockCall(multiAdapter, abi.encodeWithSelector(IMultiAdapter.updateManager.selector), "");
        vm.expectCall(multiAdapter, abi.encodeWithSelector(IMultiAdapter.updateManager.selector, poolId, who, true));
        vm.prank(AUTH);
        processor.handle(HUB_ID, _message(ManagerKind.Adapter));
    }

    /// @dev Regression: this is the escalation path where a compromised/colluding adapter quorum for a
    ///      pool can forge Gateway-manager status, which per IGateway.updateManager's own NatSpec warning
    ///      is equivalent to hub-level authority over that pool.
    function testDispatchesToGateway() public {
        _wireTargets();
        vm.mockCall(gateway, abi.encodeWithSelector(IGateway.updateManager.selector), "");
        vm.expectCall(gateway, abi.encodeWithSelector(IGateway.updateManager.selector, poolId, who, true));
        vm.prank(AUTH);
        processor.handle(HUB_ID, _message(ManagerKind.Gateway));
    }

    function testDispatchesToSpokeBridger() public {
        _wireTargets();
        vm.mockCall(spokeHandler, abi.encodeWithSelector(ISpokeGatewayHandler.updateBridger.selector), "");
        vm.expectCall(
            spokeHandler, abi.encodeWithSelector(ISpokeGatewayHandler.updateBridger.selector, poolId, who, true)
        );
        vm.prank(AUTH);
        processor.handle(HUB_ID, _message(ManagerKind.Bridger));
    }
}

contract TestHandleInvalidMessage is TestCommon {
    uint16 constant HUB_ID = 1;

    function testRevertsOnUnhandledMessageType() public {
        bytes memory message = abi.encodePacked(uint8(0));

        vm.prank(AUTH);
        vm.expectRevert(abi.encodeWithSelector(IMessageProcessor.InvalidMessage.selector, uint8(0)));
        processor.handle(HUB_ID, message);
    }
}
