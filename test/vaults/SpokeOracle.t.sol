// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../src/misc/types/D18.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AssetId} from "../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {ISpokeRegistry} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {SpokeOracle} from "../../src/vaults/oracles/SpokeOracle.sol";
import {ISpokeOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";

import "forge-std/Test.sol";

/// @dev The oracle answers one question: here are the prices, and here is whether you may trade on
///      them. The registry's own notion of validity is only "notified at least once", so these tests
///      pin what the oracle adds on top (an age bound, a coherence bound, and a pause switch) and
///      that the prices come back either way, because the unchecked conversions depend on that.
contract SpokeOracleTest is Test {
    address spokeRegistry = makeAddr("spokeRegistry");
    address envoy = makeAddr("envoy");
    address manager = makeAddr("manager");

    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16(uint128(2)));
    AssetId constant ASSET_ID = AssetId.wrap(100);

    uint64 constant MAX_AGE = 1 hours;

    function setUp() public {
        vm.warp(1_000_000);
        _mockPrices(d18(1e18), d18(2e18));
        vm.mockCall(spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.manager.selector), abi.encode(false));
        vm.mockCall(
            spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.manager.selector, POOL, manager), abi.encode(true)
        );
    }

    function _mockPrices(D18 ppa, D18 pps) internal {
        vm.mockCall(spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.pricePoolPerAsset.selector), abi.encode(ppa));
        vm.mockCall(spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.pricePoolPerShare.selector), abi.encode(pps));
    }

    function _mockComputedAt(uint64 assetAt, uint64 shareAt) internal {
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.pricePoolPerAssetComputedAt.selector),
            abi.encode(assetAt)
        );
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.pricePoolPerShareComputedAt.selector),
            abi.encode(shareAt)
        );
    }

    function _oracle(uint64 maxAge) internal returns (SpokeOracle) {
        return new SpokeOracle(ISpokeRegistry(spokeRegistry), maxAge, 0, envoy);
    }

    function _oracle(uint64 maxAge, uint64 maxSkew) internal returns (SpokeOracle) {
        return new SpokeOracle(ISpokeRegistry(spokeRegistry), maxAge, maxSkew, envoy);
    }

    function testTheConstructorAnnouncesItsBounds() public {
        vm.expectEmit(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        emit ISpokeOracle.OracleConfigured(ISpokeRegistry(spokeRegistry), 1 days, 5 minutes, envoy);
        _oracle(1 days, 5 minutes);
    }

    function _valid(SpokeOracle oracle) internal view returns (bool valid) {
        (,, valid) = oracle.prices(POOL, SC, ASSET_ID);
    }

    //----------------------------------------------------------------------------------------------
    // The prices themselves
    //----------------------------------------------------------------------------------------------

    function testFreshPricesAreValid() public {
        _mockComputedAt(uint64(block.timestamp), uint64(block.timestamp));
        (D18 ppa, D18 pps, bool valid) = _oracle(MAX_AGE).prices(POOL, SC, ASSET_ID);
        assertEq(ppa.raw(), 1e18);
        assertEq(pps.raw(), 2e18);
        assertTrue(valid);
    }

    /// @dev The single most load-bearing property of the collapsed read: a bad verdict must not
    ///      withhold the prices, because `convertTo*` and `totalAssets` value positions through them
    ///      and must answer however stale the pair is.
    function testThePricesComeBackEvenWhenTheVerdictIsBad() public {
        _mockComputedAt(uint64(block.timestamp) - MAX_AGE - 1, uint64(block.timestamp));
        (D18 ppa, D18 pps, bool valid) = _oracle(MAX_AGE).prices(POOL, SC, ASSET_ID);
        assertEq(ppa.raw(), 1e18, "asset price still reported");
        assertEq(pps.raw(), 2e18, "share price still reported");
        assertFalse(valid, "but not vouched for");
    }

    //----------------------------------------------------------------------------------------------
    // Notification
    //----------------------------------------------------------------------------------------------

    /// @dev A price that was never notified reads as zero, which converts to nothing. The oracle
    ///      subsumes the registry's own check rather than delegating to it, so this must hold even
    ///      with both bounds switched off.
    function testAnUnnotifiedPriceIsNeverValid() public {
        _mockComputedAt(0, uint64(block.timestamp));
        assertFalse(_valid(_oracle(0, 0)), "asset price never notified");

        _mockComputedAt(uint64(block.timestamp), 0);
        assertFalse(_valid(_oracle(0, 0)), "share price never notified");
    }

    function testWithNoBoundsANotifiedPairIsValidHoweverOld() public {
        _mockComputedAt(1, 2);
        assertTrue(_valid(_oracle(0, 0)));
    }

    //----------------------------------------------------------------------------------------------
    // Age
    //----------------------------------------------------------------------------------------------

    function testPriceExactlyAtMaxAgeIsValid() public {
        _mockComputedAt(uint64(block.timestamp) - MAX_AGE, uint64(block.timestamp) - MAX_AGE);
        assertTrue(_valid(_oracle(MAX_AGE)));
    }

    function testStaleAssetPriceIsInvalid() public {
        _mockComputedAt(uint64(block.timestamp) - MAX_AGE - 1, uint64(block.timestamp));
        assertFalse(_valid(_oracle(MAX_AGE)));
    }

    function testStaleSharePriceIsInvalid() public {
        _mockComputedAt(uint64(block.timestamp), uint64(block.timestamp) - MAX_AGE - 1);
        assertFalse(_valid(_oracle(MAX_AGE)));
    }

    /// @dev A `computedAt` ahead of now satisfies the upper bound indefinitely, and the further ahead
    ///      it sits the longer it would pass, so the check is bounded on both sides.
    function testFutureDatedPriceIsInvalid() public {
        _mockComputedAt(uint64(block.timestamp) + 1, uint64(block.timestamp));
        assertFalse(_valid(_oracle(MAX_AGE)));
    }

    function testZeroMaxAgeDisablesTheAgeBound() public {
        _mockComputedAt(uint64(block.timestamp) - 10 days, uint64(block.timestamp) - 10 days);
        assertTrue(_valid(_oracle(0)));
    }

    function testFuzzFreshnessBoundary(uint64 age) public {
        age = uint64(bound(age, 0, 10 days));
        _mockComputedAt(uint64(block.timestamp) - age, uint64(block.timestamp) - age);

        assertEq(_valid(_oracle(MAX_AGE)), age <= MAX_AGE);
    }

    //----------------------------------------------------------------------------------------------
    // Coherence
    //----------------------------------------------------------------------------------------------

    /// @dev Both prices inside MAX_AGE; only the gap between them is out of bounds. It is the pair,
    ///      not either price alone, that determines what a share converts to.
    function testSkewedButIndividuallyFreshPricesAreInvalid() public {
        _mockComputedAt(uint64(block.timestamp) - MAX_AGE, uint64(block.timestamp));
        assertFalse(_valid(_oracle(MAX_AGE, MAX_AGE / 2)));
    }

    function testSkewWithinBoundIsValid() public {
        _mockComputedAt(uint64(block.timestamp) - 10, uint64(block.timestamp));
        assertTrue(_valid(_oracle(MAX_AGE, 60)));
    }

    function testSkewExactlyAtTheBoundIsValid() public {
        _mockComputedAt(uint64(block.timestamp) - 60, uint64(block.timestamp));
        assertTrue(_valid(_oracle(MAX_AGE, 60)));
    }

    function testSkewOneOverTheBoundIsInvalid() public {
        _mockComputedAt(uint64(block.timestamp) - 61, uint64(block.timestamp));
        assertFalse(_valid(_oracle(MAX_AGE, 60)));
    }

    function testZeroSkewBoundDisablesTheCoherenceCheck() public {
        _mockComputedAt(uint64(block.timestamp) - MAX_AGE, uint64(block.timestamp));
        assertTrue(_valid(_oracle(MAX_AGE, 0)));
    }

    //----------------------------------------------------------------------------------------------
    // Pause
    //----------------------------------------------------------------------------------------------

    /// @dev Pausing closes the instant lane and the previews, since those are the paths that require
    ///      a verdict. Async settlement and claims are untouched: they price from the stored blended
    ///      ledger, and everything else here reads the prices without asking for the verdict.
    function testPauseInvalidatesWithoutWithholdingThePrices() public {
        _mockComputedAt(uint64(block.timestamp), uint64(block.timestamp));
        SpokeOracle oracle = _oracle(MAX_AGE);

        vm.prank(envoy);
        oracle.fromHub(POOL, abi.encode(true));

        (D18 ppa,, bool valid) = oracle.prices(POOL, SC, ASSET_ID);
        assertFalse(valid, "paused");
        assertEq(ppa.raw(), 1e18, "the price is still readable while paused");

        vm.prank(envoy);
        oracle.fromHub(POOL, abi.encode(false));
        assertTrue(_valid(oracle), "unpausing restores it");
    }

    function testPauseEmits() public {
        SpokeOracle oracle = _oracle(MAX_AGE);

        vm.expectEmit(address(oracle));
        emit ISpokeOracle.SetPaused(POOL, true, envoy);
        vm.prank(envoy);
        oracle.fromHub(POOL, abi.encode(true));
    }

    /// @dev A call that leaves the flag as it was is not a change, so it is not announced.
    function testSetPausedOnlyEmitsOnAChange() public {
        SpokeOracle oracle = _oracle(MAX_AGE);

        vm.recordLogs();
        vm.prank(envoy);
        oracle.fromHub(POOL, abi.encode(false));
        assertEq(vm.getRecordedLogs().length, 0, "unpausing an unpaused pool emits nothing");

        vm.prank(manager);
        oracle.pause(POOL);

        vm.recordLogs();
        vm.prank(manager);
        oracle.pause(POOL);
        vm.prank(envoy);
        oracle.fromHub(POOL, abi.encode(true));
        assertEq(vm.getRecordedLogs().length, 0, "pausing a paused pool emits nothing");
    }

    function testPauseIsEnvoyGated() public {
        SpokeOracle oracle = _oracle(MAX_AGE);
        vm.prank(makeAddr("notEnvoy"));
        vm.expectRevert(ISpokeOracle.NotEnvoy.selector);
        oracle.fromHub(POOL, abi.encode(true));
    }

    function testPauseRejectsValue() public {
        SpokeOracle oracle = _oracle(MAX_AGE);
        vm.deal(envoy, 1 ether);
        vm.prank(envoy);
        vm.expectRevert(ISpokeOracle.UnexpectedValue.selector);
        oracle.fromHub{value: 1}(POOL, abi.encode(true));
    }

    /// @dev One oracle serves many pools, so a pool can only close its own lane.
    function testPauseIsScopedPerPool() public {
        _mockComputedAt(uint64(block.timestamp), uint64(block.timestamp));
        SpokeOracle oracle = _oracle(MAX_AGE);
        vm.prank(envoy);
        oracle.fromHub(POOL, abi.encode(true));

        (,, bool valid) = oracle.prices(PoolId.wrap(PoolId.unwrap(POOL) + 1), SC, ASSET_ID);
        assertTrue(valid, "another pool's lane stays open");
    }

    //----------------------------------------------------------------------------------------------
    // Local pause
    //----------------------------------------------------------------------------------------------

    function testPoolManagerCanPause() public {
        SpokeOracle oracle = _oracle(MAX_AGE);
        vm.prank(manager);
        oracle.pause(POOL);
        assertTrue(oracle.isPaused(POOL));
    }

    /// @dev A local pause names the manager, so it reads apart from the hub's.
    function testALocalPauseNamesItsManager() public {
        SpokeOracle oracle = _oracle(MAX_AGE);

        vm.expectEmit(address(oracle));
        emit ISpokeOracle.SetPaused(POOL, true, manager);
        vm.prank(manager);
        oracle.pause(POOL);
    }

    /// @dev A manager of one pool cannot close another pool's lane.
    function testPoolManagerCannotPauseAnotherPool() public {
        SpokeOracle oracle = _oracle(MAX_AGE);
        vm.prank(manager);
        vm.expectRevert(ISpokeOracle.NotManager.selector);
        oracle.pause(PoolId.wrap(PoolId.unwrap(POOL) + 1));
    }

    function testOthersCannotPause() public {
        SpokeOracle oracle = _oracle(MAX_AGE);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ISpokeOracle.NotManager.selector);
        oracle.pause(POOL);
    }

    /// @dev The local pausers can only tighten: there is no local unpause, and `fromHub` stays the
    ///      Envoy's alone, so reopening the lane waits on the pool's hub policy.
    function testLocalPausersCannotUnpause() public {
        SpokeOracle oracle = _oracle(MAX_AGE);
        vm.prank(manager);
        oracle.pause(POOL);

        vm.prank(manager);
        vm.expectRevert(ISpokeOracle.NotEnvoy.selector);
        oracle.fromHub(POOL, abi.encode(false));

        vm.prank(manager);
        vm.expectRevert(ISpokeOracle.NotEnvoy.selector);
        oracle.fromHub(POOL, abi.encode(false));

        vm.prank(manager);
        oracle.pause(POOL);
        assertTrue(oracle.isPaused(POOL), "pausing twice still pauses");
    }

    function testHubUnpausesALocalPause() public {
        _mockComputedAt(uint64(block.timestamp), uint64(block.timestamp));
        SpokeOracle oracle = _oracle(MAX_AGE);
        vm.prank(manager);
        oracle.pause(POOL);

        vm.expectEmit(address(oracle));
        emit ISpokeOracle.SetPaused(POOL, false, envoy);
        vm.prank(envoy);
        oracle.fromHub(POOL, abi.encode(false));

        assertFalse(oracle.isPaused(POOL));
        assertTrue(_valid(oracle));
    }
}
