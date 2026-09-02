// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {IHub} from "../../../src/core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../src/core/types/AssetId.sol";
import {IHubRegistry} from "../../../src/core/hub/interfaces/IHubRegistry.sol";

import {OracleValuation} from "../../../src/valuations/OracleValuation.sol";
import {IOracleValuation} from "../../../src/valuations/interfaces/IOracleValuation.sol";

import "forge-std/Test.sol";

using CastLib for address;

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract OracleValuationTest is Test {
    using CastLib for *;
    PoolId constant POOL_A = PoolId.wrap(42);
    PoolId constant POOL_B = PoolId.wrap(43);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("1"));
    ShareClassId constant SC_2 = ShareClassId.wrap(bytes16("2"));
    AssetId constant C6 = AssetId.wrap(6);
    AssetId constant C18 = AssetId.wrap(18);
    uint16 constant LOCAL_CENTRIFUGE_ID = 2023;

    address hub = address(new IsContract());
    address hubRegistry = address(new IsContract());
    address envoy = makeAddr("envoy");
    address feeder = makeAddr("feeder");
    address notFeeder = makeAddr("notFeeder");
    address notDispatcher = makeAddr("notDispatcher");

    OracleValuation valuation;

    function setUp() public virtual {
        _setupMocks();
        _deployValuation();
    }

    function _setupMocks() internal {
        // Mock hubRegistry.decimals() calls using function signatures
        vm.mockCall(hubRegistry, abi.encodeWithSignature("decimals(uint128)", C6), abi.encode(6));
        vm.mockCall(hubRegistry, abi.encodeWithSignature("decimals(uint128)", C18), abi.encode(18));
        vm.mockCall(hubRegistry, abi.encodeWithSignature("decimals(uint64)", POOL_A), abi.encode(6));
        vm.mockCall(hubRegistry, abi.encodeWithSignature("decimals(uint64)", POOL_B), abi.encode(18));

        // Mock hub.updateHoldingValue() calls for all combinations we might use
        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_A, SC_1, C6), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_A, SC_1, C18), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_A, SC_2, C6), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_B, SC_1, C6), abi.encode());
    }

    function _deployValuation() internal {
        valuation = new OracleValuation(IHub(hub), IHubRegistry(hubRegistry), envoy);
    }

    /// @dev Drives feeder management through `fromHub` as the Envoy would.
    function _updateFeeder(PoolId poolId, uint16 centrifugeId, bytes32 feeder_, bool canFeed) internal {
        vm.prank(envoy);
        valuation.fromHub(poolId, abi.encode(centrifugeId, feeder_, canFeed));
    }

    function _enableFeeder(PoolId poolId, address feeder_) internal {
        _updateFeeder(poolId, 0, feeder_.toBytes32(), true);
    }

    function _setPrice(PoolId poolId, ShareClassId scId, AssetId assetId, D18 price) internal {
        vm.prank(feeder);
        valuation.setPrice(poolId, scId, assetId, price);
    }
}

contract OracleValuationConstructorTests is OracleValuationTest {
    function testConstructorSetsImmutables() public view {
        assertEq(address(valuation.hub()), hub);
        assertEq(address(valuation.hubRegistry()), hubRegistry);
        assertEq(valuation.envoy(), envoy);
    }
}

contract OracleValuationUpdateFeederTests is OracleValuationTest {
    function testUpdateFeederSuccess() public {
        vm.expectEmit(true, true, true, true);
        emit IOracleValuation.UpdateFeeder(POOL_A, 0, feeder.toBytes32(), true);

        _updateFeeder(POOL_A, 0, feeder.toBytes32(), true);

        assertTrue(valuation.feeder(POOL_A, 0, feeder.toBytes32()));
    }

    function testUpdateFeederDisable() public {
        // First enable
        _updateFeeder(POOL_A, 0, feeder.toBytes32(), true);
        assertTrue(valuation.feeder(POOL_A, 0, feeder.toBytes32()));

        // Then disable
        _updateFeeder(POOL_A, 0, feeder.toBytes32(), false);
        assertFalse(valuation.feeder(POOL_A, 0, feeder.toBytes32()));
    }

    function testFromHubNotDispatcher() public {
        vm.expectRevert(IOracleValuation.NotEnvoy.selector);
        vm.prank(notDispatcher);
        valuation.fromHub(POOL_A, abi.encode(uint16(0), feeder.toBytes32(), true));
    }

    function testFromHubUnexpectedValue() public {
        vm.deal(envoy, 1 ether);
        vm.expectRevert(IOracleValuation.UnexpectedValue.selector);
        vm.prank(envoy);
        valuation.fromHub{value: 1}(POOL_A, abi.encode(uint16(0), feeder.toBytes32(), true));
    }

    function testUpdateFeederMultipleFeeders() public {
        address feeder2 = makeAddr("feeder2");

        _updateFeeder(POOL_A, 0, feeder.toBytes32(), true);
        _updateFeeder(POOL_A, 0, feeder2.toBytes32(), true);

        assertTrue(valuation.feeder(POOL_A, 0, feeder.toBytes32()));
        assertTrue(valuation.feeder(POOL_A, 0, feeder2.toBytes32()));
    }
}

contract OracleValuationSetPriceTests is OracleValuationTest {
    function setUp() public override {
        super.setUp();
        _enableFeeder(POOL_A, feeder);
    }

    function testSetPriceSuccess() public {
        D18 price = d18(1.5e18);

        vm.expectEmit(true, true, true, true);
        emit IOracleValuation.UpdatePrice(POOL_A, SC_1, C6, price);

        _setPrice(POOL_A, SC_1, C6, price);

        (D18 storedValue, bool isValid,) = valuation.pricePoolPerAsset(POOL_A, SC_1, C6);
        assertEq(storedValue.raw(), price.raw());
        assertTrue(isValid);
    }

    function testSetPriceZeroPrice() public {
        D18 zeroPrice = d18(0);

        vm.expectEmit(true, true, true, true);
        emit IOracleValuation.UpdatePrice(POOL_A, SC_1, C6, zeroPrice);

        _setPrice(POOL_A, SC_1, C6, zeroPrice);

        (D18 storedValue, bool isValid,) = valuation.pricePoolPerAsset(POOL_A, SC_1, C6);
        assertEq(storedValue.raw(), 0);
        assertTrue(isValid); // Should be valid even with zero price
    }

    function testSetPriceNotFeeder() public {
        D18 price = d18(1.5e18);

        vm.expectRevert(IOracleValuation.NotFeeder.selector);
        vm.prank(notFeeder);
        valuation.setPrice(POOL_A, SC_1, C6, price);
    }

    function testSetPriceUpdatesMultipleTimes() public {
        D18 price1 = d18(1.0e18);
        D18 price2 = d18(2.0e18);

        // Set first price
        _setPrice(POOL_A, SC_1, C6, price1);
        (D18 storedValue1, bool isValid1,) = valuation.pricePoolPerAsset(POOL_A, SC_1, C6);
        assertEq(storedValue1.raw(), price1.raw());
        assertTrue(isValid1);

        // Update with second price
        _setPrice(POOL_A, SC_1, C6, price2);
        (D18 storedValue2, bool isValid2,) = valuation.pricePoolPerAsset(POOL_A, SC_1, C6);
        assertEq(storedValue2.raw(), price2.raw());
        assertTrue(isValid2);
    }

    function testSetPriceCallsUpdateHoldingValue() public {
        D18 price = d18(1.5e18);

        vm.expectCall(hub, abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_A, SC_1, C6));

        _setPrice(POOL_A, SC_1, C6, price);
    }
}

contract OracleValuationGetQuoteTests is OracleValuationTest {
    function setUp() public override {
        super.setUp();
        _enableFeeder(POOL_A, feeder);
        _enableFeeder(POOL_B, feeder);
    }

    function testGetQuoteSameDecimals() public {
        D18 price = d18(1.5e18);
        _setPrice(POOL_A, SC_1, C6, price);

        uint128 baseAmount = 100 * 1e6;
        uint128 expectedQuote = 150 * 1e6; // 100 * 1.5

        uint128 quote = valuation.getQuote(POOL_A, SC_1, C6, baseAmount);
        assertEq(quote, expectedQuote);
    }

    function testGetQuoteFromMoreDecimalsToLess() public {
        D18 price = d18(1.5e18);
        _setPrice(POOL_A, SC_1, C18, price);

        uint128 baseAmount = 100 * 1e18;
        uint128 expectedQuote = 150 * 1e6; // 100 * 1.5, converted from 18 to 6 decimals

        uint128 quote = valuation.getQuote(POOL_A, SC_1, C18, baseAmount);
        assertEq(quote, expectedQuote);
    }

    function testGetQuoteFromLessDecimalsToMore() public {
        D18 price = d18(1.5e18);
        _setPrice(POOL_B, SC_1, C6, price);

        uint128 baseAmount = 100 * 1e6;
        uint128 expectedQuote = 150 * 1e18; // 100 * 1.5, converted from 6 to 18 decimals

        uint128 quote = valuation.getQuote(POOL_B, SC_1, C6, baseAmount);
        assertEq(quote, expectedQuote);
    }

    function testGetQuoteWithZeroPrice() public {
        D18 zeroPrice = d18(0);
        _setPrice(POOL_A, SC_1, C6, zeroPrice);

        uint128 baseAmount = 100 * 1e6;
        uint128 expectedQuote = 0;

        uint128 quote = valuation.getQuote(POOL_A, SC_1, C6, baseAmount);
        assertEq(quote, expectedQuote);
    }

    function testGetQuoteWithZeroAmount() public {
        D18 price = d18(1.5e18);
        _setPrice(POOL_A, SC_1, C6, price);

        uint128 baseAmount = 0;
        uint128 expectedQuote = 0;

        uint128 quote = valuation.getQuote(POOL_A, SC_1, C6, baseAmount);
        assertEq(quote, expectedQuote);
    }

    function testGetQuotePriceNotSet() public {
        // Don't set any price - should revert
        uint128 baseAmount = 100 * 1e6;

        vm.expectRevert(IOracleValuation.PriceNotSet.selector);
        valuation.getQuote(POOL_A, SC_1, C6, baseAmount);
    }

    function testGetQuoteFuzzPrices(uint128 baseAmount, uint128 priceRaw) public {
        // Use reasonable bounds to avoid overflow and underflow
        vm.assume(baseAmount >= 1e6 && baseAmount <= 1e12); // 1 to 1M units in 6 decimals
        vm.assume(priceRaw >= 1e15 && priceRaw <= 1e21); // 0.001 to 1000 in 18 decimals

        D18 price = d18(priceRaw);
        _setPrice(POOL_A, SC_1, C6, price);

        // Should not revert with valid prices
        uint128 quote = valuation.getQuote(POOL_A, SC_1, C6, baseAmount);

        // Basic sanity check - quote should be non-zero for reasonable inputs
        assertGt(quote, 0);
    }
}

contract OracleValuationZeroDecimalsTests is OracleValuationTest {
    AssetId constant C0 = AssetId.wrap(100); // decimals mocked to 0
    PoolId constant POOL_C0 = PoolId.wrap(200); // currency decimals mocked to 0

    function setUp() public override {
        super.setUp();
        vm.mockCall(hubRegistry, abi.encodeWithSignature("decimals(uint128)", C0), abi.encode(0));
        vm.mockCall(hubRegistry, abi.encodeWithSignature("decimals(uint64)", POOL_C0), abi.encode(0));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_C0, SC_1, C0), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_B, SC_1, C0), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_C0, SC_1, C18), abi.encode());
        _enableFeeder(POOL_C0, feeder);
        _enableFeeder(POOL_B, feeder);
    }

    // 0-decimal asset into a 0-decimal pool: equal-decimals branch, price applied with no scaling.
    function testGetQuoteZeroDecAssetZeroDecPool() public {
        _setPrice(POOL_C0, SC_1, C0, d18(1.5e18));
        assertEq(valuation.getQuote(POOL_C0, SC_1, C0, 100), 150);
    }

    // 0-decimal asset into an 18-decimal pool: 1 whole unit becomes 1e18 fine units, exponent-safe.
    function testGetQuoteZeroDecAssetFinePool() public {
        _setPrice(POOL_B, SC_1, C0, d18(1e18));
        assertEq(valuation.getQuote(POOL_B, SC_1, C0, 1), 1e18);
    }

    // 18-decimal asset into a 0-decimal pool: 1.0 fine unit rounds to 1 whole unit.
    function testGetQuoteFineAssetZeroDecPool() public {
        _setPrice(POOL_C0, SC_1, C18, d18(1e18));
        assertEq(valuation.getQuote(POOL_C0, SC_1, C18, 1e18), 1);
    }
}

contract OracleValuationMultiAssetTests is OracleValuationTest {
    function setUp() public override {
        super.setUp();
        _enableFeeder(POOL_A, feeder);
    }

    function testMultipleAssetsIndependentPrices() public {
        D18 priceC6 = d18(1.0e18);
        D18 priceC18 = d18(2.0e18);

        // Set prices for different assets
        _setPrice(POOL_A, SC_1, C6, priceC6);
        _setPrice(POOL_A, SC_1, C18, priceC18);

        // Verify both prices are stored correctly
        (D18 storedPriceC6, bool isValidC6,) = valuation.pricePoolPerAsset(POOL_A, SC_1, C6);
        (D18 storedPriceC18, bool isValidC18,) = valuation.pricePoolPerAsset(POOL_A, SC_1, C18);

        assertEq(storedPriceC6.raw(), priceC6.raw());
        assertTrue(isValidC6);
        assertEq(storedPriceC18.raw(), priceC18.raw());
        assertTrue(isValidC18);
    }

    function testMultipleShareClassesIndependentPrices() public {
        D18 priceSC1 = d18(1.0e18);
        D18 priceSC2 = d18(2.0e18);

        // Set prices for different share classes
        _setPrice(POOL_A, SC_1, C6, priceSC1);
        _setPrice(POOL_A, SC_2, C6, priceSC2);

        // Verify both prices are stored correctly
        (D18 storedPriceSC1, bool isValidSC1,) = valuation.pricePoolPerAsset(POOL_A, SC_1, C6);
        (D18 storedPriceSC2, bool isValidSC2,) = valuation.pricePoolPerAsset(POOL_A, SC_2, C6);

        assertEq(storedPriceSC1.raw(), priceSC1.raw());
        assertTrue(isValidSC1);
        assertEq(storedPriceSC2.raw(), priceSC2.raw());
        assertTrue(isValidSC2);
    }

    function testMultiplePoolsIndependentPrices() public {
        _enableFeeder(POOL_B, feeder);

        D18 pricePoolA = d18(1.0e18);
        D18 pricePoolB = d18(2.0e18);

        // Set prices for different pools
        _setPrice(POOL_A, SC_1, C6, pricePoolA);
        _setPrice(POOL_B, SC_1, C6, pricePoolB);

        // Verify both prices are stored correctly
        (D18 storedPriceA, bool isValidA,) = valuation.pricePoolPerAsset(POOL_A, SC_1, C6);
        (D18 storedPriceB, bool isValidB,) = valuation.pricePoolPerAsset(POOL_B, SC_1, C6);

        assertEq(storedPriceA.raw(), pricePoolA.raw());
        assertTrue(isValidA);
        assertEq(storedPriceB.raw(), pricePoolB.raw());
        assertTrue(isValidB);
    }
}

contract OracleValuationEdgeCaseTests is OracleValuationTest {
    function setUp() public override {
        super.setUp();
        _enableFeeder(POOL_A, feeder);
    }

    function testMaxPrice() public {
        D18 maxPrice = D18.wrap(type(uint128).max);

        vm.expectEmit(true, true, true, true);
        emit IOracleValuation.UpdatePrice(POOL_A, SC_1, C6, maxPrice);

        _setPrice(POOL_A, SC_1, C6, maxPrice);

        (D18 storedValue, bool isValid,) = valuation.pricePoolPerAsset(POOL_A, SC_1, C6);
        assertEq(storedValue.raw(), maxPrice.raw());
        assertTrue(isValid);
    }

    function testFeederManagement() public {
        address feeder2 = makeAddr("feeder2");
        address feeder3 = makeAddr("feeder3");

        // Enable multiple feeders
        _updateFeeder(POOL_A, 0, feeder2.toBytes32(), true);
        _updateFeeder(POOL_A, 0, feeder3.toBytes32(), true);

        // All feeders should be able to set prices
        D18 price1 = d18(1.0e18);
        D18 price2 = d18(2.0e18);
        D18 price3 = d18(3.0e18);

        vm.prank(feeder);
        valuation.setPrice(POOL_A, SC_1, C6, price1);

        vm.prank(feeder2);
        valuation.setPrice(POOL_A, SC_1, C18, price2);

        vm.prank(feeder3);
        valuation.setPrice(POOL_A, SC_2, C6, price3);

        // Verify all prices were set
        (D18 storedPrice1,,) = valuation.pricePoolPerAsset(POOL_A, SC_1, C6);
        (D18 storedPrice2,,) = valuation.pricePoolPerAsset(POOL_A, SC_1, C18);
        (D18 storedPrice3,,) = valuation.pricePoolPerAsset(POOL_A, SC_2, C6);

        assertEq(storedPrice1.raw(), price1.raw());
        assertEq(storedPrice2.raw(), price2.raw());
        assertEq(storedPrice3.raw(), price3.raw());
    }
}

contract OracleValuationFromSpokeTests is OracleValuationTest {
    using CastLib for *;

    uint16 constant REMOTE_CENTRIFUGE_ID = 5;
    address remoteFeeder = makeAddr("remoteFeeder");
    AssetId remoteAsset = newAssetId(REMOTE_CENTRIFUGE_ID, 1);

    function setUp() public override {
        super.setUp();
        vm.mockCall(
            hub, abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_A, SC_1, remoteAsset), abi.encode()
        );
        _updateFeeder(POOL_A, REMOTE_CENTRIFUGE_ID, remoteFeeder.toBytes32(), true);
    }

    /// @dev Direction boundary: `fromSpoke` only performs feeder-validated price updates; feeder management
    ///      is reachable via `fromHub` (hub-supervised) exclusively. `fromSpoke` never touches the feeder
    ///      mapping, so a spoke actor cannot self-grant as a feeder even though the selector now exists.
    function testFromSpokeCannotManageFeeders() public {
        bytes32 spokeActor = makeAddr("spokeActor").toBytes32();
        bytes memory payload =
            abi.encode(ShareClassId.unwrap(SC_1), AssetId.unwrap(C6), uint128(1e18), uint64(block.timestamp));

        // A non-feeder spoke actor cannot use fromSpoke (it is not registered as a feeder).
        vm.prank(envoy);
        vm.expectRevert(IOracleValuation.NotFeeder.selector);
        valuation.fromSpoke(POOL_A, payload, REMOTE_CENTRIFUGE_ID, spokeActor);

        // The feeder mapping is untouched: fromSpoke has no path to grant feeder status.
        assertEq(valuation.feeder(POOL_A, REMOTE_CENTRIFUGE_ID, spokeActor), false);
    }

    function testFromSpokeUnexpectedValue() public {
        bytes memory payload =
            abi.encode(ShareClassId.unwrap(SC_1), AssetId.unwrap(C6), uint128(1e18), uint64(block.timestamp));

        vm.deal(envoy, 1 ether);
        vm.expectRevert(IOracleValuation.UnexpectedValue.selector);
        vm.prank(envoy);
        valuation.fromSpoke{value: 1}(POOL_A, payload, REMOTE_CENTRIFUGE_ID, remoteFeeder.toBytes32());
    }

    function testFromSpokeSuccess() public {
        D18 price = d18(1.5e18);
        bytes memory payload =
            abi.encode(ShareClassId.unwrap(SC_1), remoteAsset.raw(), price.raw(), uint64(block.timestamp));

        vm.expectEmit(true, true, true, true);
        emit IOracleValuation.UpdatePrice(POOL_A, SC_1, remoteAsset, price);

        vm.prank(envoy);
        valuation.fromSpoke(POOL_A, payload, REMOTE_CENTRIFUGE_ID, remoteFeeder.toBytes32());

        (D18 storedValue, bool isValid,) = valuation.pricePoolPerAsset(POOL_A, SC_1, remoteAsset);
        assertEq(storedValue.raw(), price.raw());
        assertTrue(isValid);
    }

    function testFromSpokeNotEnvoy() public {
        bytes memory payload =
            abi.encode(ShareClassId.unwrap(SC_1), AssetId.unwrap(C6), uint128(1e18), uint64(block.timestamp));

        vm.expectRevert(IOracleValuation.NotEnvoy.selector);
        vm.prank(makeAddr("random"));
        valuation.fromSpoke(POOL_A, payload, REMOTE_CENTRIFUGE_ID, remoteFeeder.toBytes32());
    }

    function testFromSpokeNotFeeder() public {
        bytes memory payload =
            abi.encode(ShareClassId.unwrap(SC_1), AssetId.unwrap(C6), uint128(1e18), uint64(block.timestamp));

        vm.expectRevert(IOracleValuation.NotFeeder.selector);
        vm.prank(envoy);
        valuation.fromSpoke(POOL_A, payload, REMOTE_CENTRIFUGE_ID, notFeeder.toBytes32());
    }

    function testFromSpokeWrongCentrifugeId() public {
        bytes memory payload =
            abi.encode(ShareClassId.unwrap(SC_1), AssetId.unwrap(C6), uint128(1e18), uint64(block.timestamp));

        // Feeder is registered for REMOTE_CENTRIFUGE_ID, not 999
        vm.expectRevert(IOracleValuation.NotFeeder.selector);
        vm.prank(envoy);
        valuation.fromSpoke(POOL_A, payload, 999, remoteFeeder.toBytes32());
    }

    function testFromSpokeStaleReplayRejected() public {
        uint64 t0 = uint64(block.timestamp);
        bytes memory stalePayload = abi.encode(ShareClassId.unwrap(SC_1), remoteAsset.raw(), uint128(1.5e18), t0);

        // A newer message commits a price, advancing updatedAt past t0.
        skip(10);
        bytes memory newerPayload =
            abi.encode(ShareClassId.unwrap(SC_1), remoteAsset.raw(), uint128(2e18), uint64(block.timestamp));
        vm.prank(envoy);
        valuation.fromSpoke(POOL_A, newerPayload, REMOTE_CENTRIFUGE_ID, remoteFeeder.toBytes32());

        vm.expectRevert(IOracleValuation.StalePrice.selector);
        vm.prank(envoy);
        valuation.fromSpoke(POOL_A, stalePayload, REMOTE_CENTRIFUGE_ID, remoteFeeder.toBytes32());
    }

    function testFromSpokeLocalSetPriceBlocksStaleReplay() public {
        uint64 t0 = uint64(block.timestamp);
        bytes memory stalePayload = abi.encode(ShareClassId.unwrap(SC_1), remoteAsset.raw(), uint128(1.5e18), t0);

        // A local setPrice (hub-side feeder) advances updatedAt past t0.
        skip(10);
        _enableFeeder(POOL_A, feeder);
        vm.prank(feeder);
        valuation.setPrice(POOL_A, SC_1, remoteAsset, d18(2e18));

        vm.expectRevert(IOracleValuation.StalePrice.selector);
        vm.prank(envoy);
        valuation.fromSpoke(POOL_A, stalePayload, REMOTE_CENTRIFUGE_ID, remoteFeeder.toBytes32());
    }

    function testFromSpokeUpdatedAtStoredOnSuccess() public {
        uint64 t = uint64(block.timestamp);
        bytes memory payload = abi.encode(ShareClassId.unwrap(SC_1), remoteAsset.raw(), uint128(1e18), t);
        vm.prank(envoy);
        valuation.fromSpoke(POOL_A, payload, REMOTE_CENTRIFUGE_ID, remoteFeeder.toBytes32());

        (,, uint64 updatedAt) = valuation.pricePoolPerAsset(POOL_A, SC_1, remoteAsset);
        assertEq(updatedAt, t);
    }

    function testFromSpokeNetworkMismatch() public {
        // C6 = AssetId.wrap(6) embeds centrifugeId 0, which doesn't match REMOTE_CENTRIFUGE_ID = 5.
        bytes memory payload =
            abi.encode(ShareClassId.unwrap(SC_1), AssetId.unwrap(C6), uint128(1e18), uint64(block.timestamp));

        vm.expectRevert(IOracleValuation.NetworkMismatch.selector);
        vm.prank(envoy);
        valuation.fromSpoke(POOL_A, payload, REMOTE_CENTRIFUGE_ID, remoteFeeder.toBytes32());
    }
}
