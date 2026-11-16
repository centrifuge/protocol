// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../src/misc/types/D18.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AssetId} from "../../src/core/types/AssetId.sol";
import {IHub} from "../../src/core/hub/interfaces/IHub.sol";
import {RequestId} from "../../src/core/types/RequestId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {IHoldings} from "../../src/core/hub/interfaces/IHoldings.sol";
import {IMultiAdapter} from "../../src/core/messaging/interfaces/IMultiAdapter.sol";
import {IShareClassManager} from "../../src/core/hub/interfaces/IShareClassManager.sol";

import {OrderBookAction, Fulfillment, Cancellation} from "../../src/vaults/hub/interfaces/IOrderBook.sol";

import "forge-std/Test.sol";

import {StdHubPolicy} from "../../src/policies/hub/StdHubPolicy.sol";
import {IStdHubPolicy} from "../../src/policies/hub/interfaces/IStdHubPolicy.sol";

/// @dev Exercises the OrderBook branch of {StdHubPolicy}: the fill-vs-effective fee bound and the
///      manager-price deviation bands (both asset and share price), plus the payload offset decoding.
contract OrderBookPolicyTest is Test {
    address hub = makeAddr("hub");
    address scm = makeAddr("scm");
    address sender = makeAddr("sender");
    address hubRegistry = makeAddr("hubRegistry");
    address orderBook = makeAddr("orderBook");
    address holdings = makeAddr("holdings");
    address manager = makeAddr("manager");

    PoolId poolId = PoolId.wrap(1);
    ShareClassId scId = ShareClassId.wrap(bytes16(uint128(2)));
    AssetId assetId = AssetId.wrap(100);
    RequestId requestId = RequestId.wrap((uint256(uint160(makeAddr("vault"))) << 96) | 7);
    uint16 constant LOCAL = 1;
    D18 committedAsset = d18(1e18);
    D18 committedShare = d18(2e18);

    function setUp() public {
        vm.mockCall(hub, abi.encodeWithSelector(IHub.hubRegistry.selector), abi.encode(hubRegistry));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.sender.selector), abi.encode(sender));
        vm.mockCall(sender, abi.encodeWithSignature("localCentrifugeId()"), abi.encode(LOCAL));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.pricePoolPerAsset.selector), abi.encode(committedAsset));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.holdings.selector), abi.encode(holdings));
        vm.mockCall(holdings, abi.encodeWithSelector(IHoldings.isInitialized.selector), abi.encode(true));
        vm.mockCall(
            scm,
            abi.encodeWithSelector(IShareClassManager.pricePoolPerShare.selector),
            abi.encode(committedShare, uint64(0))
        );
    }

    function _policy(uint128 maxFeeBps, uint128 maxRebateBps, uint128 maxFulfillPriceDeviation)
        internal
        returns (StdHubPolicy)
    {
        IStdHubPolicy.Config memory c;
        c.delay = 1 hours;
        c.expiry = 1 days;
        c.escalation = 2 hours;
        c.orderBook = orderBook;
        c.maxFeeBps = maxFeeBps;
        c.maxRebateBps = maxRebateBps;
        c.maxFulfillPriceDeviation = maxFulfillPriceDeviation;
        c.maxAbsolutePriceDelta = 0;
        c.thresholdPerSecond = 0;
        return new StdHubPolicy(IHub(hub), IMultiAdapter(makeAddr("ma")), IShareClassManager(scm), c);
    }

    function _fulfillCall(uint128 fill, uint128 eff, D18 ppa, D18 pps) internal view returns (bytes memory) {
        return _call(
            abi.encode(
                OrderBookAction.Fulfill,
                Fulfillment(true, scId, assetId, requestId, fill, eff, ppa, pps, 500_000, address(0))
            )
        );
    }

    function _cancelCall(uint128 amount, uint128 net) internal view returns (bytes memory) {
        return _call(
            abi.encode(
                OrderBookAction.Cancel, Cancellation(false, scId, assetId, requestId, amount, net, 500_000, address(0))
            )
        );
    }

    function _call(bytes memory inner) internal view returns (bytes memory) {
        return abi.encodeCall(
            IHub.managerCall, (poolId, LOCAL, bytes32(bytes20(orderBook)), inner, uint128(0), uint256(0), address(0))
        );
    }

    /// @dev Decoded as the OrderBook decodes it: with the extra-gas word in the payload, the fee is still
    ///      read from the amount/net fields, not from a shifted word.
    function testCancelFeeWithinBoundIsInPolicy() public {
        StdHubPolicy m = _policy(100, type(uint128).max, 0);
        assertEq(m.authorizationDelay(poolId, manager, _cancelCall(1000e6, 995e6)), 0);
    }

    function testCancelFeeAboveBoundIsOutOfPolicy() public {
        StdHubPolicy m = _policy(100, type(uint128).max, 0);
        assertEq(m.authorizationDelay(poolId, manager, _cancelCall(1000e6, 980e6)), m.delay());
    }

    /// @dev A payload too short for its action fails closed onto the timelock rather than reverting.
    function testShortPayloadsAreOutOfPolicy() public {
        StdHubPolicy m = _policy(type(uint128).max, type(uint128).max, type(uint128).max);
        assertEq(m.authorizationDelay(poolId, manager, _call(abi.encode(OrderBookAction.Cancel, 1, 2))), m.delay());
        assertEq(m.authorizationDelay(poolId, manager, _call(abi.encode(OrderBookAction.Fulfill, 1, 2))), m.delay());
    }

    /// @dev The action is one byte. A word that is not one is out of policy rather than truncated into a valid
    ///      action, which the OrderBook refuses too.
    function testAnActionWordBeyondAByteIsOutOfPolicy() public {
        StdHubPolicy m = _policy(type(uint128).max, type(uint128).max, type(uint128).max);
        bytes memory inner = abi.encode(
            uint256(0x100) + uint256(uint8(OrderBookAction.Fulfill)),
            Fulfillment(true, scId, assetId, requestId, 1000e6, 1000e6, d18(1e18), d18(1e18), 500_000, address(0))
        );
        assertEq(m.authorizationDelay(poolId, manager, _call(inner)), m.delay());
    }

    function testFeeWithinBoundIsInPolicy() public {
        StdHubPolicy m = _policy(100, type(uint128).max, type(uint128).max); // 1% fee cap, price guard off
        assertEq(m.authorizationDelay(poolId, manager, _fulfillCall(1000e6, 995e6, committedAsset, committedShare)), 0);
    }

    function testFeeAboveBoundIsOutOfPolicy() public {
        StdHubPolicy m = _policy(100, type(uint128).max, type(uint128).max);
        assertEq(
            m.authorizationDelay(poolId, manager, _fulfillCall(1000e6, 980e6, committedAsset, committedShare)),
            m.delay()
        );
    }

    /// @dev The fee this bound validates is charged rounded up (`FeeRequestManager._applyFee`), so the
    ///      bound has to round up too. Floored, a manager charging exactly the cap lands one unit over
    ///      it whenever the product does not divide evenly, and a pool configured at its own cap has
    ///      every fulfillment pushed onto the timelock, which looks like a misconfiguration rather
    ///      than a rounding mismatch.
    function testAFeeAtExactlyTheCapIsInPolicyWhenItDoesNotDivideEvenly() public {
        StdHubPolicy m = _policy(100, type(uint128).max, type(uint128).max); // 1% fee cap, price guard off

        // 1% of 1_000_000_001 is 10_000_000.01, which the producer charges as 10_000_001.
        uint128 fill = 1_000_000_001;
        uint128 fee = uint128((uint256(fill) * 100 + 9_999) / 10_000);
        assertEq(fee, 10_000_001, "the fee the manager actually charges at the cap");

        assertEq(
            m.authorizationDelay(poolId, manager, _fulfillCall(fill, fill - fee, committedAsset, committedShare)),
            0,
            "a fee at the cap is in policy"
        );
    }

    function testRebateWithinBoundIsInPolicy() public {
        StdHubPolicy m = _policy(type(uint128).max, 100, type(uint128).max); // 1% rebate cap, fee guard off
        assertEq(m.authorizationDelay(poolId, manager, _fulfillCall(1000e6, 1005e6, committedAsset, committedShare)), 0);
    }

    function testRebateAboveBoundIsOutOfPolicy() public {
        StdHubPolicy m = _policy(type(uint128).max, 100, type(uint128).max); // rebate has its own bound
        assertEq(
            m.authorizationDelay(poolId, manager, _fulfillCall(1000e6, 1020e6, committedAsset, committedShare)),
            m.delay()
        );
    }

    /// @dev Unlike the fee, nothing produces a rebate rounded up, so its bound rounds down: at one basis point a
    ///      fill of 1 may not rebate a whole unit, which would be a 100% rebate in policy.
    function testARebateBeyondTheExactRateIsOutOfPolicyWhenTheCapDoesNotDivideEvenly() public {
        StdHubPolicy m = _policy(type(uint128).max, 1, type(uint128).max); // 1 bp rebate cap, price guard off

        assertEq(
            m.authorizationDelay(poolId, manager, _fulfillCall(1, 2, committedAsset, committedShare)),
            m.delay(),
            "a rebate of 100% of the fill is not within one basis point"
        );
        assertEq(
            m.authorizationDelay(poolId, manager, _fulfillCall(9_999, 10_000, committedAsset, committedShare)),
            m.delay(),
            "a unit rebated on a fill just under 10_000 is out of policy"
        );
    }

    function testARebateAtExactlyTheRateIsInPolicy() public {
        StdHubPolicy m = _policy(type(uint128).max, 1, type(uint128).max);
        assertEq(m.authorizationDelay(poolId, manager, _fulfillCall(10_000, 10_001, committedAsset, committedShare)), 0);
    }

    function testAZeroRebateBoundAdmitsNoRebate() public {
        StdHubPolicy m = _policy(type(uint128).max, 0, type(uint128).max);
        assertEq(m.authorizationDelay(poolId, manager, _fulfillCall(1000e6, 1000e6, committedAsset, committedShare)), 0);
        assertEq(
            m.authorizationDelay(poolId, manager, _fulfillCall(1000e6, 1000e6 + 1, committedAsset, committedShare)),
            m.delay()
        );
    }

    /// @dev The bound against exact arithmetic, over every fill, rate and fee: a fee is in policy exactly when it is at
    ///      most the rate's ceiling, as the manager charges it rounded up.
    function testFuzzTheFeeBoundIsTheCeilingOfTheRate(uint128 fill, uint16 bps, uint128 fee) public {
        fill = uint128(bound(fill, 2, type(uint96).max));
        bps = uint16(bound(bps, 1, 10_000));
        fee = uint128(bound(fee, 0, fill - 1));
        StdHubPolicy m = _policy(bps, type(uint128).max, type(uint128).max);

        bool inPolicy =
            m.authorizationDelay(poolId, manager, _fulfillCall(fill, fill - fee, committedAsset, committedShare)) == 0;

        assertEq(inPolicy, uint256(fee) * 10_000 <= (uint256(fill) * bps + 9_999) / 10_000 * 10_000);
    }

    /// @dev The rebate side: a pre-funded rebate is in policy exactly when it does not exceed the rate, with no
    ///      rounding in its favour.
    function testFuzzTheRebateBoundIsTheFloorOfTheRate(uint128 fill, uint16 bps, uint128 rebate) public {
        fill = uint128(bound(fill, 1, type(uint96).max));
        bps = uint16(bound(bps, 1, 10_000));
        rebate = uint128(bound(rebate, 1, uint256(fill) * 2));
        StdHubPolicy m = _policy(type(uint128).max, bps, type(uint128).max);

        bool inPolicy = m.authorizationDelay(
            poolId, manager, _fulfillCall(fill, fill + rebate, committedAsset, committedShare)
        ) == 0;

        assertEq(inPolicy, uint256(rebate) * 10_000 <= uint256(fill) * bps);
    }

    function testPricesWithinBandIsInPolicy() public {
        StdHubPolicy m = _policy(type(uint128).max, type(uint128).max, 0); // fee/rebate off, prices exact
        assertEq(m.authorizationDelay(poolId, manager, _fulfillCall(1000e6, 1000e6, committedAsset, committedShare)), 0);
    }

    /// @dev Without a holding the hub reads the asset at 1.0, a reference nothing a fill is compared to means
    ///      anything against: with the price guard on, the fill waits out the timelock. With the guard off the
    ///      manager's own prices stand, as for any fill.
    function testAFillOnAnUninitializedHoldingIsOutOfPolicyWhileThePriceGuardIsOn() public {
        vm.mockCall(holdings, abi.encodeWithSelector(IHoldings.isInitialized.selector), abi.encode(false));

        StdHubPolicy guarded = _policy(type(uint128).max, type(uint128).max, 1000);
        assertEq(
            guarded.authorizationDelay(poolId, manager, _fulfillCall(1000e6, 1000e6, committedAsset, committedShare)),
            guarded.delay()
        );

        StdHubPolicy unguarded = _policy(type(uint128).max, type(uint128).max, type(uint128).max);
        assertEq(
            unguarded.authorizationDelay(poolId, manager, _fulfillCall(1000e6, 1000e6, committedAsset, committedShare)),
            0
        );
    }

    function testSharePriceOutOfBandIsOutOfPolicy() public {
        StdHubPolicy m = _policy(type(uint128).max, type(uint128).max, 0);
        assertEq(
            m.authorizationDelay(poolId, manager, _fulfillCall(1000e6, 1000e6, committedAsset, d18(2.1e18))), m.delay()
        );
    }

    /// @dev The OrderBook rejects a cancellation crediting more than it retires, so the policy does not
    ///      classify one as instant either, whatever the rebate bound says.
    function testRebateCancelIsOutOfPolicy() public {
        StdHubPolicy m = _policy(type(uint128).max, type(uint128).max, type(uint128).max);
        assertEq(m.authorizationDelay(poolId, manager, _cancelCall(1000e6, 1000e6 + 1)), m.delay());
        assertEq(m.authorizationDelay(poolId, manager, _cancelCall(1000e6, 1000e6)), 0, "a fee-free cancel is not");
    }

    /// @dev Setting the observer is configuration, so it waits out the timelock however lax the bounds.
    function testSetObserverIsOutOfPolicy() public {
        StdHubPolicy m = _policy(type(uint128).max, type(uint128).max, type(uint128).max);
        bytes memory inner = abi.encode(uint8(OrderBookAction.SetObserver), makeAddr("observer"));
        assertEq(m.authorizationDelay(poolId, manager, _call(inner)), m.delay());
    }

    /// @dev Without a committed price there is no reference to bound the fill against, so it fails closed.
    function testZeroCommittedPriceIsOutOfPolicy() public {
        StdHubPolicy m = _policy(type(uint128).max, type(uint128).max, 0);
        vm.mockCall(hub, abi.encodeWithSelector(IHub.pricePoolPerAsset.selector), abi.encode(d18(0)));
        assertEq(m.authorizationDelay(poolId, manager, _fulfillCall(1000e6, 1000e6, d18(0), committedShare)), m.delay());
    }

    /// @dev A policy configured without an OrderBook pins no target, so a fulfillment is out of policy.
    function testWithoutAnOrderBookFulfillmentsAreOutOfPolicy() public {
        IStdHubPolicy.Config memory c;
        c.delay = 1 hours;
        c.expiry = 1 days;
        c.escalation = 2 hours;
        c.maxFeeBps = type(uint128).max;
        c.maxRebateBps = type(uint128).max;
        c.maxFulfillPriceDeviation = type(uint128).max;
        StdHubPolicy m = new StdHubPolicy(IHub(hub), IMultiAdapter(makeAddr("ma")), IShareClassManager(scm), c);
        assertEq(
            m.authorizationDelay(poolId, manager, _fulfillCall(1000e6, 1000e6, committedAsset, committedShare)),
            m.delay()
        );
    }

    /// @dev The OrderBook pin is a local address, so the same payload sent to another chain is out of policy.
    function testRemoteFulfillmentIsOutOfPolicy() public {
        StdHubPolicy m = _policy(type(uint128).max, type(uint128).max, type(uint128).max);
        bytes memory inner = abi.encode(
            OrderBookAction.Fulfill,
            Fulfillment(true, scId, assetId, requestId, 1000e6, 1000e6, committedAsset, committedShare, 0, address(0))
        );
        bytes memory data = abi.encodeCall(
            IHub.managerCall,
            (poolId, LOCAL + 1, bytes32(bytes20(orderBook)), inner, uint128(0), uint256(0), address(0))
        );
        assertEq(m.authorizationDelay(poolId, manager, data), m.delay());
    }

    /// @dev A redeem fulfillment is bounded the same way as a deposit one.
    function testRedeemFulfillIsBounded() public {
        StdHubPolicy m = _policy(100, type(uint128).max, 0);
        assertEq(m.authorizationDelay(poolId, manager, _redeemFulfillCall(100e18, 99.5e18)), 0);
        assertEq(m.authorizationDelay(poolId, manager, _redeemFulfillCall(100e18, 98e18)), m.delay());
    }

    /// @dev A basis-point bound above 100% is meaningless, so it is rejected rather than silently lax.
    function testBpsBoundsAboveOneHundredPercentAreRejected() public {
        vm.expectRevert(IStdHubPolicy.InvalidConfig.selector);
        this.newPolicy(10_001, type(uint128).max);

        vm.expectRevert(IStdHubPolicy.InvalidConfig.selector);
        this.newPolicy(type(uint128).max, 10_001);

        this.newPolicy(10_000, 10_000);
    }

    function newPolicy(uint128 maxFeeBps, uint128 maxRebateBps) external returns (StdHubPolicy) {
        return _policy(maxFeeBps, maxRebateBps, type(uint128).max);
    }

    function _redeemFulfillCall(uint128 fill, uint128 net) internal view returns (bytes memory) {
        return _call(
            abi.encode(
                OrderBookAction.Fulfill,
                Fulfillment(false, scId, assetId, requestId, fill, net, committedAsset, committedShare, 0, address(0))
            )
        );
    }

    function testAssetPriceOutOfBandIsOutOfPolicy() public {
        StdHubPolicy m = _policy(type(uint128).max, type(uint128).max, 0);
        assertEq(
            m.authorizationDelay(poolId, manager, _fulfillCall(1000e6, 1000e6, d18(1.1e18), committedShare)), m.delay()
        );
    }
}
