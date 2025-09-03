// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";

import {IHub} from "../../../src/hub/interfaces/IHub.sol";
import {IHubRegistry} from "../../../src/hub/interfaces/IHubRegistry.sol";

import {OracleValuation} from "../../../src/valuations/OracleValuation.sol";
import {IOracleValuation} from "../../../src/valuations/interfaces/IOracleValuation.sol";

import "forge-std/Test.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract OracleValuationTest is Test {
    PoolId constant POOL_A = PoolId.wrap(42);
    PoolId constant POOL_B = PoolId.wrap(43);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("1"));
    ShareClassId constant SC_2 = ShareClassId.wrap(bytes16("2"));
    AssetId constant C6 = AssetId.wrap(6);
    AssetId constant C18 = AssetId.wrap(18);
    uint16 constant LOCAL_CENTRIFUGE_ID = 2023;

    address hub = address(new IsContract());
    address contractUpdater = makeAddr("contractUpdater");
    address hubRegistry = address(new IsContract());
    address poolManager = makeAddr("poolManager");
    address feeder = makeAddr("feeder");
    address notFeeder = makeAddr("notFeeder");
    address notManager = makeAddr("notManager");

    OracleValuation valuation;

    function setUp() public virtual {
        _setupMocks();
        _deployValuation();
    }

    function _setupMocks() internal {
        // Mock hubRegistry.manager() calls
        vm.mockCall(
            hubRegistry, abi.encodeWithSelector(IHubRegistry.manager.selector, POOL_A, poolManager), abi.encode(true)
        );
        vm.mockCall(
            hubRegistry, abi.encodeWithSelector(IHubRegistry.manager.selector, POOL_B, poolManager), abi.encode(true)
        );
        vm.mockCall(
            hubRegistry, abi.encodeWithSelector(IHubRegistry.manager.selector, POOL_A, notManager), abi.encode(false)
        );

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
        valuation = new OracleValuation(IHub(hub), contractUpdater, IHubRegistry(hubRegistry), LOCAL_CENTRIFUGE_ID);
    }

    function _enableFeeder(PoolId poolId, address feeder_) internal {
        vm.prank(poolManager);
        valuation.updateFeeder(poolId, feeder_, true);
    }

    function _setPrice(PoolId poolId, ShareClassId scId, AssetId assetId, D18 price) internal {
        vm.prank(feeder);
        valuation.setPrice(poolId, scId, assetId, price);
    }
}

contract OracleValuationConstructorTests is OracleValuationTest {
    function testConstructorSetsImmutables() public view {
        assertEq(address(valuation.hub()), hub);
        assertEq(valuation.contractUpdater(), contractUpdater);
        assertEq(address(valuation.hubRegistry()), hubRegistry);
        assertEq(valuation.localCentrifugeId(), LOCAL_CENTRIFUGE_ID);
    }
}

contract OracleValuationUpdateFeederTests is OracleValuationTest {
    function testUpdateFeederSuccess() public {
        vm.prank(poolManager);
        valuation.updateFeeder(POOL_A, feeder, true);

        assertTrue(valuation.feeder(POOL_A, feeder));
    }

    function testUpdateFeederDisable() public {
        // First enable
        vm.prank(poolManager);
        valuation.updateFeeder(POOL_A, feeder, true);
        assertTrue(valuation.feeder(POOL_A, feeder));

        // Then disable
        vm.prank(poolManager);
        valuation.updateFeeder(POOL_A, feeder, false);
        assertFalse(valuation.feeder(POOL_A, feeder));
    }

    function testUpdateFeederNotHubManager() public {
        vm.expectRevert(IOracleValuation.NotHubManager.selector);
        vm.prank(notManager);
        valuation.updateFeeder(POOL_A, feeder, true);
    }

    function testUpdateFeederMultipleFeeders() public {
        address feeder2 = makeAddr("feeder2");

        vm.startPrank(poolManager);
        valuation.updateFeeder(POOL_A, feeder, true);
        valuation.updateFeeder(POOL_A, feeder2, true);
        vm.stopPrank();

        assertTrue(valuation.feeder(POOL_A, feeder));
        assertTrue(valuation.feeder(POOL_A, feeder2));
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

        (D18 storedValue, bool isValid) = valuation.price(POOL_A, SC_1, C6);
        assertEq(storedValue.raw(), price.raw());
        assertTrue(isValid);
    }

    function testSetPriceZeroPrice() public {
        D18 zeroPrice = d18(0);

        vm.expectEmit(true, true, true, true);
        emit IOracleValuation.UpdatePrice(POOL_A, SC_1, C6, zeroPrice);

        _setPrice(POOL_A, SC_1, C6, zeroPrice);

        (D18 storedValue, bool isValid) = valuation.price(POOL_A, SC_1, C6);
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
        (D18 storedValue1, bool isValid1) = valuation.price(POOL_A, SC_1, C6);
        assertEq(storedValue1.raw(), price1.raw());
        assertTrue(isValid1);

        // Update with second price
        _setPrice(POOL_A, SC_1, C6, price2);
        (D18 storedValue2, bool isValid2) = valuation.price(POOL_A, SC_1, C6);
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
        (D18 storedPriceC6, bool isValidC6) = valuation.price(POOL_A, SC_1, C6);
        (D18 storedPriceC18, bool isValidC18) = valuation.price(POOL_A, SC_1, C18);

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
        (D18 storedPriceSC1, bool isValidSC1) = valuation.price(POOL_A, SC_1, C6);
        (D18 storedPriceSC2, bool isValidSC2) = valuation.price(POOL_A, SC_2, C6);

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
        (D18 storedPriceA, bool isValidA) = valuation.price(POOL_A, SC_1, C6);
        (D18 storedPriceB, bool isValidB) = valuation.price(POOL_B, SC_1, C6);

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

        (D18 storedValue, bool isValid) = valuation.price(POOL_A, SC_1, C6);
        assertEq(storedValue.raw(), maxPrice.raw());
        assertTrue(isValid);
    }

    function testFeederManagement() public {
        address feeder2 = makeAddr("feeder2");
        address feeder3 = makeAddr("feeder3");

        // Enable multiple feeders
        vm.startPrank(poolManager);
        valuation.updateFeeder(POOL_A, feeder2, true);
        valuation.updateFeeder(POOL_A, feeder3, true);
        vm.stopPrank();

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
        (D18 storedPrice1,) = valuation.price(POOL_A, SC_1, C6);
        (D18 storedPrice2,) = valuation.price(POOL_A, SC_1, C18);
        (D18 storedPrice3,) = valuation.price(POOL_A, SC_2, C6);

        assertEq(storedPrice1.raw(), price1.raw());
        assertEq(storedPrice2.raw(), price2.raw());
        assertEq(storedPrice3.raw(), price3.raw());
    }
}
