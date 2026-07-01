// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";

import {newAssetId} from "../../src/core/types/AssetId.sol";
import {PoolId, newPoolId} from "../../src/core/types/PoolId.sol";
import {MessageProcessor} from "../../src/core/messaging/MessageProcessor.sol";
import {IMultiAdapter} from "../../src/core/messaging/interfaces/IMultiAdapter.sol";
import {IScheduleAuth} from "../../src/core/messaging/interfaces/IScheduleAuth.sol";
import {MessageLib, ManagerKind} from "../../src/core/messaging/libraries/MessageLib.sol";
import {IMessageProcessor} from "../../src/core/messaging/interfaces/IMessageProcessor.sol";

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

contract TestSourceChecks is TestCommon {
    function testRegisterAssetOnlyFromSource() public {
        // assetId encodes centrifugeId=2, message sent from centrifugeId=1
        bytes memory message =
            MessageLib.serialize(MessageLib.RegisterAsset({assetId: newAssetId(2, 0).raw(), decimals: 18}));

        vm.prank(AUTH);
        vm.expectRevert(IMessageProcessor.OnlyFromSource.selector);
        processor.handle(1, message);
    }

    function testSetPoolAdaptersOnlyFromSource() public {
        // poolId encodes centrifugeId=2, message sent from centrifugeId=1
        bytes memory message = MessageLib.serialize(
            MessageLib.SetPoolAdapters({poolId: newPoolId(2, 0).raw(), threshold: 0, adapterList: new bytes32[](0)})
        );

        vm.prank(AUTH);
        vm.expectRevert(IMessageProcessor.OnlyFromSource.selector);
        processor.handle(1, message);
    }

    function testUpdateHoldingAmountOnlyFromSource() public {
        // assetId encodes centrifugeId=2, message sent from centrifugeId=1
        bytes memory message = MessageLib.serialize(
            MessageLib.UpdateHoldingAmount({
                poolId: 0,
                scId: bytes16(0),
                assetId: newAssetId(2, 0).raw(),
                amount: 0,
                pricePoolPerAsset: 0,
                timestamp: 0,
                isIncrease: false,
                isSnapshot: false,
                nonce: 0,
                extraGasLimit: 0
            })
        );

        vm.prank(AUTH);
        vm.expectRevert(IMessageProcessor.OnlyFromSource.selector);
        processor.handle(1, message);
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

/// @dev Pool-dependent messages handled on the spoke side must originate from the pool's home chain
///      (the Hub). A message arriving from any other chain - e.g. a compromised spoke whose adapter
///      set lives on the Hub chain - must be rejected. Conversely, spoke->hub messages legitimately
///      arrive from foreign chains and must NOT be constrained to the pool's home chain.
contract TestHandleFromSource is Test {
    using MessageLib for *;

    uint16 constant HOME_CHAIN = 1;
    uint16 constant FOREIGN_CHAIN = 2;
    // The receiving chain's own id. Distinct from HOME_CHAIN so SetPoolAdapters' on-hub guard
    // (require local != pool home) treats this processor as a spoke and accepts the message.
    uint16 constant LOCAL_SPOKE_CHAIN = 99;

    /// @param name          Message type name, surfaced when a row fails.
    /// @param message       A valid serialized message of that type.
    /// @param handler       Downstream contract the branch calls; mocked so the accepted path succeeds.
    /// @param validSource   Chain the message is legitimately accepted from: the pool's home chain for
    ///                      Hub->spoke messages; the asset's home chain (UpdateHoldingAmount) or any
    ///                      spoke for spoke->hub messages.
    /// @param rejectsOthers Whether a different source must revert with OnlyFromSource. True for
    ///                      source-constrained messages (Hub->spoke, plus asset-gated UpdateHoldingAmount).
    struct Case {
        string name;
        bytes message;
        address handler;
        uint16 validSource;
        bool rejectsOthers;
    }

    MessageProcessor processor;
    IScheduleAuth immutable scheduleAuth = IScheduleAuth(makeAddr("ScheduleAuth"));
    PoolId poolId = newPoolId(HOME_CHAIN, 42);

    function setUp() external {
        processor = new MessageProcessor(scheduleAuth, address(this));
        processor.file("spoke", makeAddr("Spoke"));
        processor.file("multiAdapter", makeAddr("MultiAdapter"));
        processor.file("hubHandler", makeAddr("HubHandler"));
        processor.file("vaultRegistry", makeAddr("VaultRegistry"));
        processor.file("contractUpdater", makeAddr("ContractUpdater"));
        processor.file("envoy", makeAddr("Envoy"));

        // SetPoolAdapters reads the local chain id to forbid configuring a pool the local chain hubs.
        // Mock it to a spoke id so the legitimate spoke delivery path is exercised. Persisted across the
        // loop (the per-iteration handler no-op mock is a less specific match, so it never shadows this).
        vm.mockCall(
            address(processor.multiAdapter()),
            abi.encodeWithSignature("localCentrifugeId()"),
            abi.encode(LOCAL_SPOKE_CHAIN)
        );
    }

    /// @dev One row per pool-dependent message type (plus SetPoolAdapters, the only Hub->spoke message
    ///      ordered before NotifyPool). The loop below asserts the source check is applied per direction.
    ///      Adding a message type here keeps the per-branch reject/accept coverage in lockstep with the
    ///      exhaustive isHubToSpoke classification asserted in MessageLib.t.sol.
    function _cases() internal view returns (Case[] memory cases) {
        address spoke_ = address(processor.spoke());
        address adapter_ = address(processor.multiAdapter());
        address hub_ = address(processor.hubHandler());
        address vault_ = address(processor.vaultRegistry());
        address updater_ = address(processor.contractUpdater());
        address envoy_ = address(processor.envoy());
        uint64 p = poolId.raw();

        cases = new Case[](21);

        // Hub->spoke: only valid coming from the pool's home chain.
        cases[0] = Case(
            "SetPoolAdapters",
            MessageLib.SetPoolAdapters({poolId: p, threshold: 0, adapterList: new bytes32[](0)}).serialize(),
            adapter_,
            HOME_CHAIN,
            true
        );
        cases[1] = Case("NotifyPool", MessageLib.NotifyPool({poolId: p}).serialize(), spoke_, HOME_CHAIN, true);
        cases[2] = Case(
            "NotifyShareClass",
            MessageLib.NotifyShareClass({
                    poolId: p,
                    scId: bytes16("sc"),
                    name: "name",
                    symbol: bytes32("SYM"),
                    decimals: 6,
                    salt: bytes32("salt"),
                    hook: bytes32("hook")
                }).serialize(),
            spoke_,
            HOME_CHAIN,
            true
        );
        cases[3] = Case(
            "NotifyPricePoolPerShare",
            MessageLib.NotifyPricePoolPerShare({poolId: p, scId: bytes16("sc"), price: 1, timestamp: 0}).serialize(),
            spoke_,
            HOME_CHAIN,
            true
        );
        cases[4] = Case(
            "NotifyPricePoolPerAsset",
            MessageLib.NotifyPricePoolPerAsset({poolId: p, scId: bytes16("sc"), assetId: 1, price: 1, timestamp: 0})
                .serialize(),
            spoke_,
            HOME_CHAIN,
            true
        );
        cases[5] = Case(
            "NotifyShareMetadata",
            MessageLib.NotifyShareMetadata({poolId: p, scId: bytes16("sc"), name: "name", symbol: bytes32("SYM")})
                .serialize(),
            spoke_,
            HOME_CHAIN,
            true
        );
        cases[6] = Case(
            "UpdateShareHook",
            MessageLib.UpdateShareHook({poolId: p, scId: bytes16("sc"), hook: bytes32("hook")}).serialize(),
            spoke_,
            HOME_CHAIN,
            true
        );
        cases[7] = Case(
            "ExecuteTransferShares",
            MessageLib.ExecuteTransferShares({
                    poolId: p, scId: bytes16("sc"), receiver: bytes32("receiver"), amount: 1, extraGasLimit: 0
                }).serialize(),
            spoke_,
            HOME_CHAIN,
            true
        );
        cases[8] = Case(
            "UpdateRestriction",
            MessageLib.UpdateRestriction({poolId: p, scId: bytes16("sc"), extraGasLimit: 0, payload: bytes("")})
                .serialize(),
            spoke_,
            HOME_CHAIN,
            true
        );
        cases[9] = Case(
            "UpdateVault",
            MessageLib.UpdateVault({
                    poolId: p,
                    scId: bytes16("sc"),
                    assetId: 1,
                    vaultOrFactory: bytes32("vault"),
                    kind: 0,
                    extraGasLimit: 0
                }).serialize(),
            vault_,
            HOME_CHAIN,
            true
        );
        cases[10] = Case(
            "SetMaxAssetPriceAge",
            MessageLib.SetMaxAssetPriceAge({poolId: p, scId: bytes16("sc"), assetId: 1, maxPriceAge: 0}).serialize(),
            spoke_,
            HOME_CHAIN,
            true
        );
        cases[11] = Case(
            "SetMaxSharePriceAge",
            MessageLib.SetMaxSharePriceAge({poolId: p, scId: bytes16("sc"), maxPriceAge: 0}).serialize(),
            spoke_,
            HOME_CHAIN,
            true
        );
        cases[12] = Case(
            "RequestCallback",
            MessageLib.RequestCallback({
                    poolId: p, scId: bytes16("sc"), assetId: 1, extraGasLimit: 0, payload: bytes("")
                }).serialize(),
            spoke_,
            HOME_CHAIN,
            true
        );
        cases[13] = Case(
            "SetRequestManager",
            MessageLib.SetRequestManager({poolId: p, manager: bytes32("manager")}).serialize(),
            spoke_,
            HOME_CHAIN,
            true
        );
        cases[14] = Case(
            "ManagerCall",
            MessageLib.ManagerCall({poolId: p, target: bytes32("target"), extraGasLimit: 0, payload: bytes("")})
                .serialize(),
            envoy_,
            HOME_CHAIN,
            true
        );
        cases[15] = Case(
            "UpdateManager",
            MessageLib.UpdateManager({
                    poolId: p, kind: uint8(ManagerKind.Adapter), who: bytes32("manager"), canManage: true
                }).serialize(),
            adapter_,
            HOME_CHAIN,
            true
        );

        // Spoke->hub (the exclusion list in isHubToSpoke): legitimately arrives from a foreign spoke.
        cases[16] = Case(
            "InitiateTransferShares",
            MessageLib.InitiateTransferShares({
                    poolId: p,
                    scId: bytes16("sc"),
                    centrifugeId: HOME_CHAIN,
                    receiver: bytes32("receiver"),
                    amount: 1,
                    remoteExtraGasLimit: 0,
                    extraGasLimit: 0
                }).serialize(),
            hub_,
            FOREIGN_CHAIN,
            false
        );
        // UpdateHoldingAmount is spoke->hub (not pool-origin gated) but carries its own asset-origin
        // check, so it is only accepted from the asset's home chain. The asset home (FOREIGN) is kept
        // distinct from the pool home (HOME) so a dropped isHubToSpoke exclusion - which would re-add a
        // pool-origin gate - is still caught: it would reject the FOREIGN source this row accepts.
        cases[17] = Case(
            "UpdateHoldingAmount",
            MessageLib.UpdateHoldingAmount({
                    poolId: p,
                    scId: bytes16("sc"),
                    assetId: newAssetId(FOREIGN_CHAIN, 0).raw(),
                    amount: 1,
                    pricePoolPerAsset: 0,
                    timestamp: 0,
                    isIncrease: true,
                    isSnapshot: false,
                    nonce: 0,
                    extraGasLimit: 0
                }).serialize(),
            hub_,
            FOREIGN_CHAIN,
            true
        );
        cases[18] = Case(
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
            hub_,
            FOREIGN_CHAIN,
            false
        );
        cases[19] = Case(
            "Request",
            MessageLib.Request({poolId: p, scId: bytes16("sc"), assetId: 1, extraGasLimit: 0, payload: bytes("")})
                .serialize(),
            hub_,
            FOREIGN_CHAIN,
            false
        );
        cases[20] = Case(
            "UntrustedContractUpdate",
            MessageLib.UntrustedContractUpdate({
                    poolId: p,
                    scId: bytes16("sc"),
                    target: bytes32("target"),
                    sender: bytes32("sender"),
                    extraGasLimit: 0,
                    payload: bytes("")
                }).serialize(),
            updater_,
            FOREIGN_CHAIN,
            false
        );
    }

    function testHandleAppliesSourceCheckPerMessageType() public {
        Case[] memory cases = _cases();

        for (uint256 i; i < cases.length; i++) {
            Case memory c = cases[i];
            uint16 otherSource = c.validSource == HOME_CHAIN ? FOREIGN_CHAIN : HOME_CHAIN;

            // No-op the branch's downstream handler so an accepted message completes.
            vm.mockCall(c.handler, bytes(""), bytes(""));

            // Accepted from its valid source chain.
            processor.handle(c.validSource, c.message);

            // Source-constrained messages must be rejected from any other chain.
            if (c.rejectsOthers) {
                vm.expectRevert(IMessageProcessor.OnlyFromSource.selector);
                processor.handle(otherSource, c.message);
            }
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

    function testFileSpoke() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("spoke", address(23));
        processor.file("spoke", address(23));
        assertEq(address(processor.spoke()), address(23));
    }

    function testFileBalanceSheet() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("balanceSheet", address(23));
        processor.file("balanceSheet", address(23));
        assertEq(address(processor.balanceSheet()), address(23));
    }

    function testFileVaultRegistry() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("vaultRegistry", address(23));
        processor.file("vaultRegistry", address(23));
        assertEq(address(processor.vaultRegistry()), address(23));
    }

    function testFileContractUpdater() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("contractUpdater", address(23));
        processor.file("contractUpdater", address(23));
        assertEq(address(processor.contractUpdater()), address(23));
    }
}

contract TestHandleSetPoolAdapters is TestCommon {
    using MessageLib for *;

    uint16 constant HUB_ID = 1;
    uint16 constant SPOKE_ID = 2;
    address multiAdapter = makeAddr("multiAdapter");
    PoolId poolId = newPoolId(HUB_ID, 1); // pool hubbed on HUB_ID

    function _message() internal returns (bytes memory) {
        bytes32[] memory adapters = new bytes32[](1);
        adapters[0] = bytes32(bytes20(makeAddr("adapter")));
        return MessageLib.SetPoolAdapters({poolId: poolId.raw(), threshold: 1, adapterList: adapters}).serialize();
    }

    function _fileMultiAdapter() internal {
        vm.prank(AUTH);
        processor.file("multiAdapter", multiAdapter);
    }

    function testRevertsWhenLocalChainIsPoolHub() public {
        _fileMultiAdapter();
        // This chain hubs the pool: an inbound SetPoolAdapters for it must be rejected.
        vm.mockCall(multiAdapter, abi.encodeWithSelector(IMultiAdapter.localCentrifugeId.selector), abi.encode(HUB_ID));

        vm.prank(AUTH);
        vm.expectRevert(IMessageProcessor.CannotSetAdaptersOnHub.selector);
        processor.handle(HUB_ID, _message()); // source == pool hub, passes OnlyFromSource
    }

    function testRevertsWhenSourceIsNotPoolHub() public {
        _fileMultiAdapter();
        vm.prank(AUTH);
        vm.expectRevert(IMessageProcessor.OnlyFromSource.selector);
        processor.handle(SPOKE_ID, _message()); // source != pool hub
    }

    function testAcceptedOnSpoke() public {
        _fileMultiAdapter();
        // Local chain is a spoke (not the pool hub) and the message comes from the hub: it is applied.
        vm.mockCall(
            multiAdapter, abi.encodeWithSelector(IMultiAdapter.localCentrifugeId.selector), abi.encode(SPOKE_ID)
        );
        vm.mockCall(multiAdapter, abi.encodeWithSelector(IMultiAdapter.setAdapters.selector), "");

        vm.expectCall(multiAdapter, abi.encodeWithSelector(IMultiAdapter.setAdapters.selector));
        vm.prank(AUTH);
        processor.handle(HUB_ID, _message());
    }
}
