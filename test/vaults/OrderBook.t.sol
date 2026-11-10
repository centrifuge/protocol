// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../src/misc/types/D18.sol";
import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {MathLib} from "../../src/misc/libraries/MathLib.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AssetId} from "../../src/core/types/AssetId.sol";
import {RequestId} from "../../src/core/types/RequestId.sol";
import {PricingLib} from "../../src/core/libraries/PricingLib.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {IGateway} from "../../src/core/messaging/interfaces/IGateway.sol";
import {IHubRegistry} from "../../src/core/hub/interfaces/IHubRegistry.sol";
import {IHubRequestManagerCallback} from "../../src/core/hub/interfaces/IHubRequestManagerCallback.sol";

import {RequestMessageLib} from "../../src/vaults/messaging/libraries/RequestMessageLib.sol";
import {RequestCallbackMessageLib} from "../../src/vaults/messaging/libraries/RequestCallbackMessageLib.sol";

import {OrderBook} from "../../src/vaults/hub/OrderBook.sol";
import {IRequestObserver} from "../../src/vaults/hub/interfaces/IRequestObserver.sol";
import {IOrderBook, OrderBookAction, Fulfillment, Cancellation} from "../../src/vaults/hub/interfaces/IOrderBook.sol";

import "forge-std/Test.sol";

/// @dev Records every callback the OrderBook dispatches so tests can assert the wire output.
contract MockHubCallback is IHubRequestManagerCallback {
    bytes[] public payloads;
    uint128 public lastExtraGasLimit;
    uint256 public lastValue;

    function requestCallback(
        PoolId,
        ShareClassId,
        AssetId,
        bytes calldata payload,
        uint128 extraGasLimit,
        bool,
        address
    ) external payable {
        payloads.push(payload);
        lastExtraGasLimit = extraGasLimit;
        lastValue = msg.value;
    }

    function count() external view returns (uint256) {
        return payloads.length;
    }

    function last() external view returns (bytes memory) {
        return payloads[payloads.length - 1];
    }
}

/// @dev Minimal stand-in for the gateway's batching: opens the batch, calls the batcher back, and
///      enforces the lockCallback handshake, so tests exercise the OrderBook's real callback wiring.
contract MockGateway {
    uint256 public batches;
    uint256 public lastValue;
    address public lastRefund;
    address transient batcher;

    function withBatch(bytes memory data, address refund) external payable {
        batches++;
        lastValue = msg.value;
        lastRefund = refund;
        batcher = msg.sender;
        (bool success, bytes memory returnData) = msg.sender.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(32, returnData), mload(returnData))
            }
        }
        require(batcher == address(0), "callback not locked");
    }

    function lockCallback() external {
        require(msg.sender == batcher, "not batcher");
        batcher = address(0);
    }
}

contract MockObserver is IRequestObserver {
    uint256 public calls;
    uint128 public lastAmount;
    bool public shouldRevert;

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function onRequest(PoolId, ShareClassId, AssetId, RequestId, bool, uint128 amount) external {
        calls++;
        lastAmount = amount;
        if (shouldRevert) revert("observer");
    }
}

contract OrderBookTest is Test {
    using RequestMessageLib for *;
    using RequestCallbackMessageLib for bytes;

    OrderBook orderBook;
    MockHubCallback hubCb;
    MockObserver observer;
    MockGateway gateway;

    address hubRegistry = makeAddr("hubRegistry");
    address envoy = makeAddr("envoy");

    PoolId poolId = PoolId.wrap(1);
    ShareClassId scId = ShareClassId.wrap(bytes16(uint128(2)));
    AssetId assetId = AssetId.wrap(100);
    RequestId requestId = RequestId.wrap((uint256(uint160(makeAddr("vault"))) << 96) | 7);

    uint8 constant ASSET_DECIMALS = 6;
    uint8 constant POOL_DECIMALS = 18;
    D18 ppa = d18(1e18);
    D18 pps = d18(2e18);

    function setUp() public {
        gateway = new MockGateway();
        hubCb = new MockHubCallback();
        orderBook = new OrderBook(
            IHubRegistry(hubRegistry),
            IHubRequestManagerCallback(address(hubCb)),
            IGateway(address(gateway)),
            envoy,
            address(this)
        );
        observer = new MockObserver();

        vm.mockCall(
            hubRegistry, abi.encodeWithSelector(bytes4(keccak256("decimals(uint128)"))), abi.encode(ASSET_DECIMALS)
        );
        vm.mockCall(
            hubRegistry, abi.encodeWithSelector(bytes4(keccak256("decimals(uint64)"))), abi.encode(POOL_DECIMALS)
        );

        _setObserver(address(observer));
    }

    //----------------------------------------------------------------------------------------------
    // Requests (auto-approved)
    //----------------------------------------------------------------------------------------------

    function testDepositRequestAutoApproves() public {
        _request(true, 1000e6);
        assertEq(orderBook.depositOrders(poolId, scId, assetId, requestId), 1000e6);
        assertEq(observer.lastAmount(), 1000e6);
    }

    function testRequestsAggregate() public {
        _request(true, 1000e6);
        _request(true, 500e6);
        assertEq(orderBook.depositOrders(poolId, scId, assetId, requestId), 1500e6);
    }

    /// @dev The observer is the pool's choice, so its revert fails the request message, which the
    ///      gateway keeps for retry.
    function testObserverRevertFailsTheRequest() public {
        observer.setRevert(true);
        vm.expectRevert("observer");
        _request(true, 500e6);
    }

    //----------------------------------------------------------------------------------------------
    // Deposit fulfillment + fee
    //----------------------------------------------------------------------------------------------

    function testFulfillDepositAppliesFeeAsFewerShares() public {
        _request(true, 1000e6);

        uint128 fill = 1000e6;
        uint128 net = 990e6; // 1% fee
        _fulfill(true, fill, net);

        assertEq(orderBook.depositOrders(poolId, scId, assetId, requestId), 0);

        uint128 expectedShares =
            PricingLib.assetToShareAmount(net, ASSET_DECIMALS, POOL_DECIMALS, ppa, pps, MathLib.Rounding.Down);
        uint128 noFeeShares =
            PricingLib.assetToShareAmount(fill, ASSET_DECIMALS, POOL_DECIMALS, ppa, pps, MathLib.Rounding.Down);
        assertLt(expectedShares, noFeeShares, "fee must reduce shares");

        // Release, issue and fulfil ride in one callback, so the three legs cannot land apart.
        assertEq(hubCb.count(), 1);
        RequestCallbackMessageLib.SettledDeposit memory f = hubCb.payloads(0).deserializeSettledDeposit();
        assertEq(f.requestId.raw(), requestId.raw());
        assertEq(f.fulfilledAssetAmount, fill);
        assertEq(f.fulfilledShareAmount, expectedShares);
    }

    /// @dev A fill's conversion rounds in the pool's favour: down on both sides, so a price that does not divide the
    ///      amount evenly never issues or pays the investor the extra unit.
    function testFulfillConversionsRoundDown() public {
        pps = d18(3e18);
        _request(true, 1000e6);
        _fulfill(true, 1000e6, 1000e6);
        uint128 down =
            PricingLib.assetToShareAmount(1000e6, ASSET_DECIMALS, POOL_DECIMALS, ppa, pps, MathLib.Rounding.Down);
        uint128 up = PricingLib.assetToShareAmount(1000e6, ASSET_DECIMALS, POOL_DECIMALS, ppa, pps, MathLib.Rounding.Up);
        assertLt(down, up, "the price does not divide the amount evenly");
        assertEq(hubCb.last().deserializeSettledDeposit().fulfilledShareAmount, down, "the deposit issues rounded down");

        ppa = d18(7e18);
        _request(false, 100e18);
        _fulfill(false, 100e18, 100e18);
        down = PricingLib.shareToAssetAmount(100e18, POOL_DECIMALS, ASSET_DECIMALS, pps, ppa, MathLib.Rounding.Down);
        up = PricingLib.shareToAssetAmount(100e18, POOL_DECIMALS, ASSET_DECIMALS, pps, ppa, MathLib.Rounding.Up);
        assertLt(down, up, "the price does not divide the shares evenly");
        assertEq(hubCb.last().deserializeSettledRedeem().fulfilledAssetAmount, down, "the redemption pays rounded down");
    }

    function testPartialFulfillLeavesRemainder() public {
        _request(true, 1000e6);
        _fulfill(true, 600e6, 600e6);
        assertEq(orderBook.depositOrders(poolId, scId, assetId, requestId), 400e6);
    }

    function testFulfillRevertsOnOverfill() public {
        _request(true, 1000e6);
        vm.expectRevert(IOrderBook.InsufficientOutstanding.selector);
        _fulfill(true, 1100e6, 1100e6);
    }

    /// @dev The engine wraps its callback in a batch of its own, so the forwarded value pays for it
    ///      without the caller needing any batching discipline.
    function testFulfillOpensItsOwnBatch() public {
        _request(true, 1000e6);
        _fulfill(true, 1000e6, 1000e6);
        assertEq(gateway.batches(), 1);
        assertEq(hubCb.count(), 1);
    }

    /// @dev The batch body is only reachable as the gateway's callback into the engine.
    function testFulfillCallbackOnlyViaBatch() public {
        vm.expectRevert(bytes("not batcher"));
        orderBook.fulfillCallback(
            poolId, Fulfillment(true, scId, assetId, requestId, 1000e6, 1000e6, ppa, pps, 0, address(0))
        );
    }

    /// @dev A cancel sends a single callback, so it does not open a batch.
    function testCancelSendsWithoutABatch() public {
        _request(true, 1000e6);
        _cancel(true, 400e6);
        assertEq(gateway.batches(), 0);
        assertEq(orderBook.depositOrders(poolId, scId, assetId, requestId), 600e6);
    }

    function testCancelDepositRefundsRemainder() public {
        _request(true, 1000e6);
        _cancel(true, 400e6);
        assertEq(orderBook.depositOrders(poolId, scId, assetId, requestId), 600e6);
        RequestCallbackMessageLib.CancelledDeposit memory c = hubCb.last().deserializeCancelledDeposit();
        assertEq(c.grossAssetAmount, 400e6);
        assertEq(c.netAssetAmount, 400e6);
    }

    function testCancelDepositRefundsNetAmount() public {
        _request(true, 1000e6);
        _cancel(true, 400e6, 380e6); // fee withheld on cancellation
        assertEq(orderBook.depositOrders(poolId, scId, assetId, requestId), 600e6);
        // Both numbers ride the wire: gross releases the reservation, net is what the investor gets.
        RequestCallbackMessageLib.CancelledDeposit memory c = hubCb.last().deserializeCancelledDeposit();
        assertEq(c.grossAssetAmount, 400e6);
        assertEq(c.netAssetAmount, 380e6);
    }

    /// @dev The redeem twin: a fee kept on a cancelled redemption reaches the spoke as the gap between the two.
    function testCancelRedeemRefundsNetAmount() public {
        _request(false, 100e18);
        _cancel(false, 40e18, 38e18);
        assertEq(orderBook.redeemOrders(poolId, scId, assetId, requestId), 60e18);
        RequestCallbackMessageLib.CancelledRedeem memory c = hubCb.last().deserializeCancelledRedeem();
        assertEq(c.grossShareAmount, 40e18);
        assertEq(c.netShareAmount, 38e18);
    }

    //----------------------------------------------------------------------------------------------
    // Redeem fulfillment + fee
    //----------------------------------------------------------------------------------------------

    function testFulfillRedeemAppliesFeeAsFewerAssets() public {
        _request(false, 100e18); // 100 shares

        uint128 fill = 100e18;
        uint128 net = 95e18; // 5% fee
        _fulfill(false, fill, net);

        uint128 expectedPayout =
            PricingLib.shareToAssetAmount(net, POOL_DECIMALS, ASSET_DECIMALS, pps, ppa, MathLib.Rounding.Down);
        uint128 noFeePayout =
            PricingLib.shareToAssetAmount(fill, POOL_DECIMALS, ASSET_DECIMALS, pps, ppa, MathLib.Rounding.Down);
        assertLt(expectedPayout, noFeePayout, "fee must reduce payout");

        // Revoke (burn + reserve payout) and fulfil ride in one callback.
        assertEq(hubCb.count(), 1);
        RequestCallbackMessageLib.SettledRedeem memory f = hubCb.payloads(0).deserializeSettledRedeem();
        assertEq(f.requestId.raw(), requestId.raw());
        assertEq(f.fulfilledShareAmount, fill);
        assertEq(f.fulfilledAssetAmount, expectedPayout);
    }

    //----------------------------------------------------------------------------------------------
    // Auth
    //----------------------------------------------------------------------------------------------

    function testFromHubOnlyEnvoy() public {
        vm.expectRevert(IOrderBook.NotEnvoy.selector);
        orderBook.fromHub(
            poolId,
            abi.encode(OrderBookAction.Cancel, Cancellation(true, scId, assetId, requestId, 1, 1, 0, address(0)))
        );
    }

    function testHubIsSetAtConstruction() public view {
        assertEq(address(orderBook.hub()), address(hubCb));
    }

    function testRequestIsWardGated() public {
        bytes memory payload = RequestMessageLib.serialize(RequestMessageLib.DepositRequest(requestId, 1e6));

        vm.prank(makeAddr("outsider"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        orderBook.request(poolId, scId, assetId, payload);
    }

    /// @dev The request wire carries only deposits and redeems; anything else is a message this engine
    ///      does not implement, and silently ignoring it would drop an escrowed request.
    function testUnknownRequestTypeReverts() public {
        vm.expectRevert(RequestMessageLib.UnknownRequestType.selector);
        orderBook.request(poolId, scId, assetId, abi.encodePacked(uint8(0), bytes32(requestId.raw()), uint128(1)));
    }

    /// @dev An out-of-range action never reaches `UnknownAction`: the `OrderBookAction(uint8)`
    ///      conversion panics first, so every action byte is either one of the three handled kinds or
    ///      a revert. The `UnknownAction` arm is unreachable defence, kept for when the enum grows.
    /// @dev Action zero is the enum's `Invalid` placeholder, so it decodes cleanly and falls past every
    ///      branch. It is the one bad action the enum conversion cannot catch.
    function testTheInvalidActionReverts() public {
        vm.expectRevert(IOrderBook.UnknownAction.selector);
        _fromHub(abi.encode(uint256(0)));
    }

    /// @dev The action word is decoded as a byte, so one that is not a byte reverts instead of being truncated
    ///      into a valid action.
    function testAnActionWordBeyondAByteReverts() public {
        vm.expectRevert();
        _fromHub(abi.encode(uint256(0x100) + uint256(uint8(OrderBookAction.Cancel))));
    }

    function testOutOfRangeActionReverts() public {
        vm.expectRevert(stdError.enumConversionError);
        _fromHub(abi.encode(uint256(200)));
    }

    function testZeroFillReverts() public {
        _request(true, 1000e6);

        vm.expectRevert(IOrderBook.ZeroAmount.selector);
        _fulfill(true, 0, 0);
    }

    function testZeroCancelReverts() public {
        _request(true, 1000e6);

        vm.expectRevert(IOrderBook.ZeroAmount.selector);
        _cancel(true, 0);
    }

    function testCancelBeyondOutstandingReverts() public {
        _request(true, 1000e6);

        vm.expectRevert(IOrderBook.InsufficientOutstanding.selector);
        _cancel(true, 1000e6 + 1);
    }

    /// @dev Setting an observer moves no value, so accepting one would strand it in the engine.
    function testSetObserverRejectsValue() public {
        vm.deal(envoy, 1 ether);
        vm.prank(envoy);
        vm.expectRevert(IOrderBook.UnexpectedValue.selector);
        orderBook.fromHub{value: 1}(poolId, abi.encode(uint8(OrderBookAction.SetObserver), address(observer)));
    }

    function testRequestsRunWithoutAnObserver() public {
        _setObserver(address(0));

        _request(true, 1000e6);
        assertEq(orderBook.depositOrders(poolId, scId, assetId, requestId), 1000e6, "the order is still recorded");
        assertEq(observer.calls(), 0, "and the old observer is not consulted");
    }

    /// @dev A fill that converts to nothing would retire the investor's request and consume the
    ///      escrowed assets while crediting nothing back, which the vault rejects. The engine refuses
    ///      it here rather than emitting a callback that can never be applied and never retried away.
    function testFulfillmentThatConvertsToNothingIsRejected() public {
        _request(true, 1000e6);
        pps = d18(0);

        vm.expectRevert(IOrderBook.ZeroAmount.selector);
        _fulfill(true, 1000e6, 1000e6);

        assertEq(orderBook.depositOrders(poolId, scId, assetId, requestId), 1000e6, "the order is untouched");
    }

    /// @dev Redeem orders are keyed separately from deposit orders, so a redeem fulfillment cannot
    ///      consume a deposit order standing at the same request id.
    function testSidesAreKeptSeparate() public {
        _request(true, 1000e6);

        vm.expectRevert(IOrderBook.InsufficientOutstanding.selector);
        _fulfill(false, 1000e6, 1000e6);
    }

    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    function testSetObserverEmits() public {
        address obs = makeAddr("newObserver");
        vm.expectEmit(address(orderBook));
        emit IOrderBook.SetObserver(poolId, obs);
        _setObserver(obs);
    }

    function testDepositRequestEmits() public {
        vm.expectEmit(address(orderBook));
        emit IOrderBook.DepositRequested(poolId, scId, assetId, requestId, 1000e6);
        _request(true, 1000e6);
    }

    function testRedeemRequestEmits() public {
        vm.expectEmit(address(orderBook));
        emit IOrderBook.RedeemRequested(poolId, scId, assetId, requestId, 100e18);
        _request(false, 100e18);
    }

    /// @dev The event carries the fill, the net and the converted output, so an indexer can read the
    ///      fee (`fill - net`) and the price the order settled at without decoding the callback.
    function testFulfillEmits(bool isDeposit) public {
        uint128 fill = isDeposit ? 1000e6 : 100e18;
        uint128 net = fill / 100 * 99;
        _request(isDeposit, fill);
        uint128 output = isDeposit
            ? PricingLib.assetToShareAmount(net, ASSET_DECIMALS, POOL_DECIMALS, ppa, pps, MathLib.Rounding.Down)
            : PricingLib.shareToAssetAmount(net, POOL_DECIMALS, ASSET_DECIMALS, pps, ppa, MathLib.Rounding.Down);

        vm.expectEmit(address(orderBook));
        emit IOrderBook.Fulfill(poolId, scId, assetId, requestId, isDeposit, fill, net, output, ppa, pps);
        _fulfill(isDeposit, fill, net);
    }

    function testCancelEmits(bool isDeposit) public {
        _request(isDeposit, 1000e6);

        vm.expectEmit(address(orderBook));
        emit IOrderBook.Cancel(poolId, scId, assetId, requestId, isDeposit, 400e6, 380e6);
        _cancel(isDeposit, 400e6, 380e6);
    }

    /// @dev The forwarded value pays for the batch the engine opens: it reaches the gateway with the
    ///      manager's refund address, and the callback inside the batch carries none of its own.
    function testFulfillValuePaysTheBatch() public {
        _request(true, 1000e6);
        address refund = makeAddr("refund");
        vm.deal(envoy, 1 ether);

        vm.prank(envoy);
        orderBook.fromHub{value: 1 ether}(
            poolId,
            abi.encode(
                OrderBookAction.Fulfill,
                Fulfillment(true, scId, assetId, requestId, 1000e6, 1000e6, ppa, pps, 0, refund)
            )
        );

        assertEq(gateway.lastValue(), 1 ether, "the batch is paid");
        assertEq(gateway.lastRefund(), refund, "with the manager's refund address");
        assertEq(hubCb.lastValue(), 0, "the callback inside the batch carries no value");
    }

    /// @dev A cancellation opens no batch, so its value pays the callback directly.
    function testCancelValuePaysTheCallback() public {
        _request(true, 1000e6);
        vm.deal(envoy, 1 ether);

        vm.prank(envoy);
        orderBook.fromHub{value: 1 ether}(
            poolId,
            abi.encode(
                OrderBookAction.Cancel, Cancellation(true, scId, assetId, requestId, 400e6, 400e6, 0, address(0))
            )
        );

        assertEq(hubCb.lastValue(), 1 ether);
    }

    //----------------------------------------------------------------------------------------------
    // Regressions
    //----------------------------------------------------------------------------------------------

    /// @dev A cancellation credits at most what it retires, whatever the pool policy allows: a redeem
    ///      refund above the cancelled shares would be paid out of other investors' escrowed shares.
    function testCancelNetAboveAmountReverts(bool isDeposit) public {
        _request(isDeposit, 1000e6);

        vm.expectRevert(IOrderBook.NetExceedsGross.selector);
        _cancel(isDeposit, 10e6, 10e6 + 1);

        assertEq(_outstanding(isDeposit), 1000e6, "the order is untouched");
    }

    /// @dev The manager's extra gas reaches the settlement callback, so a pool with a heavy spoke side
    ///      can fund it.
    function testFulfillForwardsExtraGas() public {
        _request(true, 1000e6);
        _fulfill(true, 1000e6, 1000e6, 123_456);
        assertEq(hubCb.lastExtraGasLimit(), 123_456);
    }

    function testCancelForwardsExtraGas() public {
        _request(false, 1000e6);
        _cancel(false, 400e6, 400e6, 654_321);
        assertEq(hubCb.lastExtraGasLimit(), 654_321);
    }

    /// @dev The struct encoding is the single wire layout: it matches the hand-written tuple it
    ///      replaced word for word, which is what the pool policy and a wrapping manager rely on.
    function testCancellationLayoutMatchesTheTuple() public view {
        assertEq(
            abi.encode(OrderBookAction.Cancel, Cancellation(true, scId, assetId, requestId, 5, 4, 3, address(0))),
            abi.encode(
                uint8(OrderBookAction.Cancel),
                true,
                ShareClassId.unwrap(scId),
                assetId.raw(),
                requestId.raw(),
                uint128(5),
                uint128(4),
                uint128(3),
                address(0)
            )
        );
    }

    function _outstanding(bool isDeposit) internal view returns (uint128) {
        return isDeposit
            ? orderBook.depositOrders(poolId, scId, assetId, requestId)
            : orderBook.redeemOrders(poolId, scId, assetId, requestId);
    }

    //----------------------------------------------------------------------------------------------
    // A fill's arithmetic never panics
    //----------------------------------------------------------------------------------------------

    /// @dev Whatever the decimals, the prices, the fill and the net a fee leaves, a fulfillment either goes through or
    ///      is refused by name. An arithmetic panic would be a callback no retry can apply, with the order stranded.
    function testFuzzAFillNeverFailsWithAnArithmeticPanic(
        bool isDeposit,
        uint8 assetDecimals,
        uint8 poolDecimals,
        uint128 ppaRaw,
        uint128 ppsRaw,
        uint128 fill,
        uint128 net
    ) public {
        vm.mockCall(
            hubRegistry,
            abi.encodeWithSelector(bytes4(keccak256("decimals(uint128)"))),
            abi.encode(uint8(bound(assetDecimals, 0, 30)))
        );
        vm.mockCall(
            hubRegistry,
            abi.encodeWithSelector(bytes4(keccak256("decimals(uint64)"))),
            abi.encode(uint8(bound(poolDecimals, 0, 30)))
        );
        fill = uint128(bound(fill, 1, type(uint128).max));
        _request(isDeposit, fill);

        bytes memory payload = abi.encode(
            OrderBookAction.Fulfill,
            Fulfillment(
                isDeposit,
                scId,
                assetId,
                requestId,
                fill,
                net,
                D18.wrap(uint128(bound(ppaRaw, 0, type(uint128).max))),
                D18.wrap(uint128(bound(ppsRaw, 0, type(uint128).max))),
                0,
                address(0)
            )
        );
        vm.prank(envoy);
        (bool success, bytes memory ret) = address(orderBook).call(abi.encodeCall(orderBook.fromHub, (poolId, payload)));
        if (!success && ret.length >= 36 && bytes4(ret) == 0x4e487b71) {
            uint256 code;
            assembly ("memory-safe") {
                code := mload(add(ret, 36))
            }
            assertTrue(code != 0x11 && code != 0x12, "a fill failed with an arithmetic panic");
        }
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    function _request(bool isDeposit, uint128 amount) internal {
        bytes memory payload = isDeposit
            ? RequestMessageLib.serialize(RequestMessageLib.DepositRequest(requestId, amount))
            : RequestMessageLib.serialize(RequestMessageLib.RedeemRequest(requestId, amount));
        orderBook.request(poolId, scId, assetId, payload);
    }

    function _fulfill(bool isDeposit, uint128 fill, uint128 net) internal {
        _fulfill(isDeposit, fill, net, 0);
    }

    function _fulfill(bool isDeposit, uint128 fill, uint128 net, uint128 extraGasLimit) internal {
        _fromHub(
            abi.encode(
                OrderBookAction.Fulfill,
                Fulfillment(isDeposit, scId, assetId, requestId, fill, net, ppa, pps, extraGasLimit, address(0))
            )
        );
    }

    function _cancel(bool isDeposit, uint128 amount) internal {
        _cancel(isDeposit, amount, amount);
    }

    function _cancel(bool isDeposit, uint128 amount, uint128 net) internal {
        _cancel(isDeposit, amount, net, 0);
    }

    function _cancel(bool isDeposit, uint128 amount, uint128 net, uint128 extraGasLimit) internal {
        _fromHub(
            abi.encode(
                OrderBookAction.Cancel,
                Cancellation(isDeposit, scId, assetId, requestId, amount, net, extraGasLimit, address(0))
            )
        );
    }

    function _fromHub(bytes memory payload) internal {
        vm.prank(envoy);
        orderBook.fromHub(poolId, payload);
    }

    function _setObserver(address obs) internal {
        vm.prank(envoy);
        orderBook.fromHub(poolId, abi.encode(uint8(OrderBookAction.SetObserver), obs));
    }
}
