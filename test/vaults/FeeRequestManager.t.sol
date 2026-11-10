// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../src/misc/types/D18.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AssetId} from "../../src/core/types/AssetId.sol";
import {IHub} from "../../src/core/hub/interfaces/IHub.sol";
import {RequestId} from "../../src/core/types/RequestId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {IHoldings} from "../../src/core/hub/interfaces/IHoldings.sol";
import {IHubPolicy} from "../../src/core/utils/interfaces/IPolicy.sol";
import {IGateway} from "../../src/core/messaging/interfaces/IGateway.sol";
import {IHubRegistry} from "../../src/core/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "../../src/core/hub/interfaces/IShareClassManager.sol";

import {FeeRequestManager} from "../../src/vaults/hub/FeeRequestManager.sol";
import {IFeeRequestManager, FeeManagerAction} from "../../src/vaults/hub/interfaces/IFeeRequestManager.sol";
import {IOrderBook, OrderBookAction, Fulfillment, Cancellation} from "../../src/vaults/hub/interfaces/IOrderBook.sol";

import "forge-std/Test.sol";

/// @dev Runs the callback of whoever opens a batch, counting the batches opened: what the gateway does for a
///      `multicall`, without its message plumbing.
contract MockBatchGateway {
    uint256 public batches;
    address internal _batcher;

    function withBatch(bytes memory data, address) external payable {
        batches++;
        _batcher = msg.sender;
        (bool success, bytes memory ret) = msg.sender.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function lockCallback() external {
        require(msg.sender == _batcher, "not the batcher");
        _batcher = address(0);
    }
}

/// @dev Verifies the wrapper reads the committed prices and forwards the fee-adjusted net amount
///      to the OrderBook via Hub.managerCall.
contract FeeRequestManagerTest is Test {
    FeeRequestManager frm;

    address hub = makeAddr("hub");
    address scm = makeAddr("scm");
    address sender = makeAddr("sender");
    address hubRegistry = makeAddr("hubRegistry");
    address orderBook = makeAddr("orderBook");
    address holdings = makeAddr("holdings");
    MockBatchGateway gateway = new MockBatchGateway();
    address envoy = makeAddr("envoy");
    address manager = makeAddr("manager");

    PoolId poolId = PoolId.wrap(1);
    ShareClassId scId = ShareClassId.wrap(bytes16(uint128(2)));
    AssetId assetId = AssetId.wrap(100);
    RequestId requestId = RequestId.wrap((uint256(uint160(makeAddr("vault"))) << 96) | 7);
    uint16 constant LOCAL = 1;
    D18 ppa = d18(1e18);
    D18 pps = d18(2e18);

    function setUp() public {
        vm.mockCall(hub, abi.encodeWithSelector(IHub.sender.selector), abi.encode(sender));
        vm.mockCall(sender, abi.encodeWithSignature("localCentrifugeId()"), abi.encode(LOCAL));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.hubRegistry.selector), abi.encode(hubRegistry));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.shareClassManager.selector), abi.encode(scm));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.pricePoolPerAsset.selector), abi.encode(ppa));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.holdings.selector), abi.encode(holdings));
        vm.mockCall(holdings, abi.encodeWithSelector(IHoldings.isInitialized.selector), abi.encode(true));
        vm.mockCall(
            scm, abi.encodeWithSelector(IShareClassManager.pricePoolPerShare.selector), abi.encode(pps, uint64(0))
        );
        vm.mockCall(hubRegistry, abi.encodeWithSelector(IHubRegistry.manager.selector), abi.encode(true));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.managerCall.selector), "");
        vm.mockCall(hub, abi.encodeWithSelector(IHub.policy.selector), abi.encode(address(0)));

        frm = new FeeRequestManager(IHub(hub), IOrderBook(orderBook), envoy, IGateway(address(gateway)));
    }

    function _setFee(uint16 bps) internal {
        vm.prank(envoy);
        frm.fromHub(poolId, abi.encode(uint8(FeeManagerAction.SetFee), assetId.raw(), bps));
    }

    function testSetFeeStores() public {
        _setFee(100);
        assertEq(frm.feeBps(poolId, assetId), 100);
    }

    function testSetFeeEmits() public {
        vm.expectEmit(address(frm));
        emit IFeeRequestManager.SetFee(poolId, assetId, 250);
        _setFee(250);
    }

    /// @dev Indexers key the fee by pool and asset: every change, a reset to zero included, is emitted
    ///      under its own pair, and a refused change emits nothing.
    function testSetFeeEmitsPerPoolAndAssetOnEveryChange() public {
        PoolId otherPool = PoolId.wrap(2);
        AssetId otherAsset = AssetId.wrap(101);

        vm.startPrank(envoy);
        vm.expectEmit(true, true, false, true, address(frm));
        emit IFeeRequestManager.SetFee(poolId, assetId, 9_999);
        frm.fromHub(poolId, abi.encode(uint8(FeeManagerAction.SetFee), assetId.raw(), uint16(9_999)));

        vm.expectEmit(true, true, false, true, address(frm));
        emit IFeeRequestManager.SetFee(poolId, otherAsset, 10);
        frm.fromHub(poolId, abi.encode(uint8(FeeManagerAction.SetFee), otherAsset.raw(), uint16(10)));

        vm.expectEmit(true, true, false, true, address(frm));
        emit IFeeRequestManager.SetFee(otherPool, assetId, 20);
        frm.fromHub(otherPool, abi.encode(uint8(FeeManagerAction.SetFee), assetId.raw(), uint16(20)));

        vm.expectEmit(true, true, false, true, address(frm));
        emit IFeeRequestManager.SetFee(poolId, assetId, 0);
        frm.fromHub(poolId, abi.encode(uint8(FeeManagerAction.SetFee), assetId.raw(), uint16(0)));

        vm.recordLogs();
        vm.expectRevert(IFeeRequestManager.FeeTooHigh.selector);
        frm.fromHub(poolId, abi.encode(uint8(FeeManagerAction.SetFee), assetId.raw(), uint16(10_000)));
        vm.stopPrank();

        assertEq(vm.getRecordedLogs().length, 0, "a refused change emits nothing");
        assertEq(frm.feeBps(poolId, assetId), 0);
        assertEq(frm.feeBps(poolId, otherAsset), 10);
        assertEq(frm.feeBps(otherPool, assetId), 20);
    }

    /// @dev The fulfillment's price and amounts are the OrderBook's `Fulfill`; the wrapper adds only the manager that
    ///      called, with the rate charged, so the fee is read without joining `SetFee`. A cancellation takes no fee
    ///      and the wrapper logs nothing for it.
    function testFulfillEmitsTheFeeChargedAndCancelNothing() public {
        _setFee(100);

        vm.expectEmit(true, true, false, true, address(frm));
        emit IFeeRequestManager.FeeCharged(poolId, requestId, manager, true, 1000e6, 990e6, 100);
        vm.prank(manager);
        frm.fulfill(poolId, scId, assetId, requestId, true, 1000e6, 0, address(0));

        vm.recordLogs();
        vm.prank(manager);
        frm.cancel(poolId, scId, assetId, requestId, false, 1e18, 0, address(0));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /// @dev Inside a multicall the caller is the one who sent it, not the gateway, and an unset fee logs a rate of zero.
    function testFeeChargedNamesTheMulticallSenderAndAZeroRate() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(frm.fulfill, (poolId, scId, assetId, requestId, true, 500e6, uint128(0), address(0)));

        vm.expectEmit(true, true, false, true, address(frm));
        emit IFeeRequestManager.FeeCharged(poolId, requestId, manager, true, 500e6, 500e6, 0);
        vm.prank(manager);
        frm.multicall(calls);
    }

    /// @dev A redemption's fee is in shares, so the event says which side it took.
    function testFeeChargedOnARedemptionSaysSo() public {
        _setFee(100);

        vm.expectEmit(true, true, false, true, address(frm));
        emit IFeeRequestManager.FeeCharged(poolId, requestId, manager, false, 1000e18, 990e18, 100);
        vm.prank(manager);
        frm.fulfill(poolId, scId, assetId, requestId, false, 1000e18, 0, address(0));
    }

    function testSetFeeOnlyEnvoy() public {
        vm.expectRevert(IFeeRequestManager.NotEnvoy.selector);
        frm.fromHub(poolId, abi.encode(uint8(FeeManagerAction.SetFee), assetId.raw(), uint16(100)));
    }

    /// @dev Exactly 100% is rejected: the net would be zero, consuming the fill and crediting nothing.
    function testSetFeeTooHigh() public {
        vm.prank(envoy);
        vm.expectRevert(IFeeRequestManager.FeeTooHigh.selector);
        frm.fromHub(poolId, abi.encode(uint8(FeeManagerAction.SetFee), assetId.raw(), uint16(10_000)));
    }

    function testDepositFulfillForwardsNetAmountAndBothPrices() public {
        _setFee(100); // 1%

        uint128 fill = 1000e6;
        uint128 expectedNet = 990e6;
        bytes memory inner = _fulfillInner(true, fill, expectedNet, 50_000);
        bytes memory expected = abi.encodeCall(
            IHub.managerCall, (poolId, LOCAL, bytes32(bytes20(orderBook)), inner, uint128(0), uint256(0), address(0))
        );

        vm.expectCall(hub, expected);
        vm.prank(manager);
        frm.fulfill(poolId, scId, assetId, requestId, true, fill, 50_000, address(0));
    }

    function testRedeemFulfillForwardsNetAmount() public {
        _setFee(500); // 5%

        uint128 fill = 100e18;
        uint128 expectedNet = 95e18;
        bytes memory inner = _fulfillInner(false, fill, expectedNet, 0);
        bytes memory expected = abi.encodeCall(
            IHub.managerCall, (poolId, LOCAL, bytes32(bytes20(orderBook)), inner, uint128(0), uint256(0), address(0))
        );

        vm.expectCall(hub, expected);
        vm.prank(manager);
        frm.fulfill(poolId, scId, assetId, requestId, false, fill, 0, address(0));
    }

    function testNoFeeForwardsFullAmount() public {
        uint128 fill = 1000e6;
        bytes memory inner = _fulfillInner(true, fill, fill, 0);
        bytes memory expected = abi.encodeCall(
            IHub.managerCall, (poolId, LOCAL, bytes32(bytes20(orderBook)), inner, uint128(0), uint256(0), address(0))
        );

        vm.expectCall(hub, expected);
        vm.prank(manager);
        frm.fulfill(poolId, scId, assetId, requestId, true, fill, 0, address(0));
    }

    /// @dev Callers are gated on being a registered manager of the pool, reusing the Hub's own
    ///      authorization rather than a private ledger. Both entry points move value, so both check.
    function testFulfillOnlyFromAPoolManager() public {
        vm.mockCall(hubRegistry, abi.encodeWithSelector(IHubRegistry.manager.selector), abi.encode(false));

        vm.prank(makeAddr("outsider"));
        vm.expectRevert(IFeeRequestManager.NotManager.selector);
        frm.fulfill(poolId, scId, assetId, requestId, true, 1000e6, 0, address(0));
    }

    function testCancelOnlyFromAPoolManager() public {
        vm.mockCall(hubRegistry, abi.encodeWithSelector(IHubRegistry.manager.selector), abi.encode(false));

        vm.prank(makeAddr("outsider"));
        vm.expectRevert(IFeeRequestManager.NotManager.selector);
        frm.cancel(poolId, scId, assetId, requestId, true, 1000e6, 0, address(0));
    }

    /// @dev Cancellations carry no fee here: the investor gets back exactly what was retired, so the
    ///      gross and net amounts on the wire are equal.
    function testCancelForwardsTheFullAmount() public {
        _setFee(100);

        bytes memory inner = abi.encode(
            OrderBookAction.Cancel, Cancellation(true, scId, assetId, requestId, 1000e6, 1000e6, 0, address(0))
        );

        vm.expectCall(
            hub,
            abi.encodeCall(
                IHub.managerCall,
                (poolId, LOCAL, bytes32(bytes20(orderBook)), inner, uint128(0), uint256(0), address(0))
            )
        );
        vm.prank(manager);
        frm.cancel(poolId, scId, assetId, requestId, true, 1000e6, 0, address(0));
    }

    function testUnknownConfigurationActionReverts() public {
        vm.prank(envoy);
        vm.expectRevert(IFeeRequestManager.UnknownAction.selector);
        frm.fromHub(poolId, abi.encode(uint8(42), assetId.raw(), uint16(100)));
    }

    /// @dev The fee rounds up, so a fill small enough that a floored fee would vanish still pays one
    ///      unit: the hub-side mirror of the spoke policy's rounding.
    function testFeeRoundsUp(uint128 fill, uint16 bps) public {
        bps = uint16(bound(bps, 1, 9_999));
        fill = uint128(bound(fill, 1, 1e30));
        _setFee(bps);

        vm.expectCall(hub, abi.encodeWithSelector(IHub.managerCall.selector));
        vm.prank(manager);
        frm.fulfill(poolId, scId, assetId, requestId, true, fill, 0, address(0));
    }

    /// @dev 1 bp of 1001 is 0.1001, which a floored fee drops: the net is the fill less the ceiled fee.
    function testFeeIsCeiledOffTheNetForwarded() public {
        _setFee(1);

        uint128 fill = 1001;
        bytes memory inner = _fulfillInner(true, fill, 1000, 0);
        bytes memory expected = abi.encodeCall(
            IHub.managerCall, (poolId, LOCAL, bytes32(bytes20(orderBook)), inner, uint128(0), uint256(0), address(0))
        );

        vm.expectCall(hub, expected);
        vm.prank(manager);
        frm.fulfill(poolId, scId, assetId, requestId, true, fill, 0, address(0));
    }

    function _fulfillInner(bool isDeposit, uint128 fill, uint128 net, uint128 extraGasLimit)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            OrderBookAction.Fulfill,
            Fulfillment(isDeposit, scId, assetId, requestId, fill, net, ppa, pps, extraGasLimit, address(0))
        );
    }

    //----------------------------------------------------------------------------------------------
    // Regressions
    //----------------------------------------------------------------------------------------------

    /// @dev The wrapper's payload is exactly the tuple the OrderBook's own action uses, word for word:
    ///      the struct encoding is the single layout, and the hand-written tuple it replaced must match.
    function testPayloadMatchesTheHandWrittenTuple() public view {
        assertEq(
            _fulfillInner(true, 10, 9, 7),
            abi.encode(
                uint8(OrderBookAction.Fulfill),
                true,
                ShareClassId.unwrap(scId),
                assetId.raw(),
                requestId.raw(),
                uint128(10),
                uint128(9),
                ppa.raw(),
                pps.raw(),
                uint128(7),
                address(0)
            )
        );
    }

    /// @dev SetFee moves no value, and the manager has no way to return any: accepting it would strand it.
    function testSetFeeRejectsValue() public {
        vm.deal(envoy, 1 ether);
        vm.prank(envoy);
        vm.expectRevert(IFeeRequestManager.UnexpectedValue.selector);
        frm.fromHub{value: 1}(poolId, abi.encode(uint8(FeeManagerAction.SetFee), assetId.raw(), uint16(100)));
    }

    /// @dev The policy is asked about the original caller, not only about this contract: a caller it
    ///      confines (here, by reverting) cannot fulfil or cancel through the wrapper.
    function testPolicyIsConsultedForTheOriginalCaller() public {
        address policy = makeAddr("policy");
        vm.mockCall(hub, abi.encodeWithSelector(IHub.policy.selector), abi.encode(policy));
        bytes memory data = abi.encodeCall(
            IHub.managerCall,
            (poolId, LOCAL, bytes32(bytes20(orderBook)), _fulfillInner(true, 1000e6, 1000e6, 0), 0, 0, address(0))
        );
        vm.mockCallRevert(
            policy, abi.encodeCall(IHubPolicy.authorizationDelay, (poolId, manager, data)), bytes("confined")
        );

        vm.prank(manager);
        vm.expectRevert(bytes("confined"));
        frm.fulfill(poolId, scId, assetId, requestId, true, 1000e6, 0, address(0));
    }

    /// @dev Only an in-policy call passes: one the policy would hold on the timelock for the caller
    ///      cannot be laundered through the wrapper's own classification.
    function testOutOfPolicyForTheCallerReverts() public {
        address policy = makeAddr("policy");
        vm.mockCall(hub, abi.encodeWithSelector(IHub.policy.selector), abi.encode(policy));
        vm.mockCall(policy, abi.encodeWithSelector(IHubPolicy.authorizationDelay.selector), abi.encode(uint48(1)));

        vm.prank(manager);
        vm.expectRevert(IFeeRequestManager.NotInPolicy.selector);
        frm.cancel(poolId, scId, assetId, requestId, true, 1000e6, 0, address(0));

        vm.mockCall(policy, abi.encodeWithSelector(IHubPolicy.authorizationDelay.selector), abi.encode(uint48(0)));
        vm.prank(manager);
        frm.cancel(poolId, scId, assetId, requestId, true, 1000e6, 0, address(0));
    }

    /// @dev Without a holding the hub reads the asset at 1.0, a price a fill must not take: the wrapper refuses.
    function testFulfillRefusesAnUninitializedHolding() public {
        vm.mockCall(holdings, abi.encodeWithSelector(IHoldings.isInitialized.selector), abi.encode(false));

        vm.prank(manager);
        vm.expectRevert(IFeeRequestManager.HoldingNotInitialized.selector);
        frm.fulfill(poolId, scId, assetId, requestId, true, 1000e6, 0, address(0));
    }

    /// @dev Many fills in one `multicall` open one gateway batch, so their settlement callbacks leave as one message
    ///      per destination, each still going to the hub as a call of the wrapper.
    function testManyFillsInOneMulticallOpenOneBatch() public {
        bytes memory inner = _fulfillInner(true, 1000e6, 1000e6, 0);
        bytes memory expected = abi.encodeCall(
            IHub.managerCall, (poolId, LOCAL, bytes32(bytes20(orderBook)), inner, uint128(0), uint256(0), address(0))
        );
        bytes[] memory calls = new bytes[](3);
        for (uint256 i; i < calls.length; i++) {
            calls[i] =
                abi.encodeCall(frm.fulfill, (poolId, scId, assetId, requestId, true, 1000e6, uint128(0), address(0)));
        }

        vm.expectCall(hub, expected, 3);
        vm.prank(manager);
        frm.multicall(calls);
        assertEq(gateway.batches(), 1, "one batch for all three fills");
    }

    /// @dev Fulfill and cancel are the same plain manager call: neither opens a batch of its own, and a multicall of
    ///      both joins one batch, as fills alone do.
    function testFulfillAndCancelAreSymmetricManagerCalls() public {
        vm.startPrank(manager);
        frm.fulfill(poolId, scId, assetId, requestId, true, 1000e6, uint128(0), address(0));
        frm.cancel(poolId, scId, assetId, requestId, true, 1000e6, 0, address(0));
        assertEq(gateway.batches(), 0, "a single call opens no batch of its own");

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(frm.fulfill, (poolId, scId, assetId, requestId, true, 1000e6, uint128(0), address(0)));
        calls[1] = abi.encodeCall(frm.cancel, (poolId, scId, assetId, requestId, true, 1000e6, 0, address(0)));
        frm.multicall(calls);
        vm.stopPrank();
        assertEq(gateway.batches(), 1, "a fill and a cancellation share one batch");
    }

    /// @dev Inside the batch the caller is still whoever sent the multicall, not the gateway: a stranger's
    ///      multicall is refused as a stranger's single call is, and the gateway is no manager.
    function testMulticallStillNeedsAPoolManager() public {
        address outsider = makeAddr("outsider");
        vm.mockCall(hubRegistry, abi.encodeWithSelector(IHubRegistry.manager.selector), abi.encode(false));
        vm.mockCall(
            hubRegistry, abi.encodeWithSelector(IHubRegistry.manager.selector, poolId, manager), abi.encode(true)
        );
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(frm.fulfill, (poolId, scId, assetId, requestId, true, 1000e6, uint128(0), address(0)));

        vm.prank(outsider);
        vm.expectRevert(IFeeRequestManager.NotManager.selector);
        frm.multicall(calls);

        vm.prank(manager);
        frm.multicall(calls);
    }
}
