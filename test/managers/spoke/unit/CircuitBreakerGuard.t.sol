// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CircuitBreakerGuard} from "../../../../src/managers/spoke/guards/CircuitBreakerGuard.sol";
import {ICircuitBreakerGuard} from "../../../../src/managers/spoke/guards/interfaces/ICircuitBreakerGuard.sol";

import "forge-std/Test.sol";

// ─── Tally Tests ────────────────────────────────────────────────────────────

contract CircuitBreakerTallyTest is Test {
    CircuitBreakerGuard guard;
    bytes32 key = keccak256("bridge-usdc");
    uint256 constant MAX = 1_000_000e6;
    uint256 constant WINDOW = 1 days;

    function setUp() public {
        guard = new CircuitBreakerGuard();
    }

    function testSingleTallyWithinLimit() public {
        guard.tally(key, 500_000e6, MAX, WINDOW);
        (uint128 total,) = guard.cumulative(address(this), key);
        assertEq(total, 500_000e6);
    }

    function testMultipleTalliesAccumulate() public {
        guard.tally(key, 300_000e6, MAX, WINDOW);
        guard.tally(key, 400_000e6, MAX, WINDOW);
        (uint128 total,) = guard.cumulative(address(this), key);
        assertEq(total, 700_000e6);
    }

    function testTallyExactLimitPasses() public {
        guard.tally(key, MAX, MAX, WINDOW);
        (uint128 total,) = guard.cumulative(address(this), key);
        assertEq(total, MAX);
    }

    function testTallyExceedsLimitReverts() public {
        guard.tally(key, 600_000e6, MAX, WINDOW);
        vm.expectRevert(ICircuitBreakerGuard.ExceedsLimit.selector);
        guard.tally(key, 500_000e6, MAX, WINDOW);
    }

    function testTallyResetsAfterWindowExpiry() public {
        guard.tally(key, 900_000e6, MAX, WINDOW);
        vm.warp(block.timestamp + WINDOW + 1);
        guard.tally(key, 900_000e6, MAX, WINDOW);
        (uint128 total,) = guard.cumulative(address(this), key);
        assertEq(total, 900_000e6);
    }

    function testTallyDoesNotResetBeforeWindowExpiry() public {
        guard.tally(key, 600_000e6, MAX, WINDOW);
        vm.warp(block.timestamp + WINDOW - 1);
        vm.expectRevert(ICircuitBreakerGuard.ExceedsLimit.selector);
        guard.tally(key, 500_000e6, MAX, WINDOW);
    }

    function testTallyIsolatesKeys() public {
        bytes32 keyB = keccak256("bridge-weth");
        guard.tally(key, 900_000e6, MAX, WINDOW);
        guard.tally(keyB, 900_000e6, MAX, WINDOW);
        (uint128 totalA,) = guard.cumulative(address(this), key);
        (uint128 totalB,) = guard.cumulative(address(this), keyB);
        assertEq(totalA, 900_000e6);
        assertEq(totalB, 900_000e6);
    }

    function testTallyIsolatesCallers() public {
        guard.tally(key, 900_000e6, MAX, WINDOW);
        vm.prank(makeAddr("other"));
        guard.tally(key, 900_000e6, MAX, WINDOW);
        (uint128 totalThis,) = guard.cumulative(address(this), key);
        (uint128 totalOther,) = guard.cumulative(makeAddr("other"), key);
        assertEq(totalThis, 900_000e6);
        assertEq(totalOther, 900_000e6);
    }

    function testFuzzTallyAccumulation(uint128 a, uint128 b) public {
        uint256 max = type(uint128).max;
        guard.tally(key, a, max, WINDOW);
        if (uint256(a) + uint256(b) > max) {
            vm.expectRevert();
            guard.tally(key, b, max, WINDOW);
        } else {
            guard.tally(key, b, max, WINDOW);
            (uint128 total,) = guard.cumulative(address(this), key);
            assertEq(total, uint256(a) + uint256(b));
        }
    }
}

// ─── Delta Tests ────────────────────────────────────────────────────────────

contract CircuitBreakerDeltaTest is Test {
    CircuitBreakerGuard guard;
    bytes32 key = keccak256("share-price");
    uint256 constant MAX_BPS = 500; // 5%
    uint256 constant WINDOW = 1 days;

    function setUp() public {
        guard = new CircuitBreakerGuard();
    }

    function testFirstCallAnchorsToCurrentValue() public {
        guard.delta(key, 1000, 1040, MAX_BPS, WINDOW);
        (uint128 anchor, uint64 windowStart) = guard.refs(address(this), key);
        assertEq(anchor, 1000);
        assertEq(windowStart, block.timestamp);
    }

    function testWithinWindowUsesStoredAnchor() public {
        guard.delta(key, 1000, 1020, MAX_BPS, WINDOW);

        // Second call within window — currentValue is ignored, anchor stays 1000
        guard.delta(key, 9999, 1049, MAX_BPS, WINDOW);
        (uint128 anchor,) = guard.refs(address(this), key);
        assertEq(anchor, 1000);
    }

    function testExactBoundaryPasses() public {
        // 5% of 1000 = 50, so 1050 should pass
        guard.delta(key, 1000, 1050, MAX_BPS, WINDOW);
    }

    function testExceedsBoundaryReverts() public {
        // 5% of 1000 = 50, so 1051 should fail
        vm.expectRevert(ICircuitBreakerGuard.ExceedsLimit.selector);
        guard.delta(key, 1000, 1051, MAX_BPS, WINDOW);
    }

    function testNegativeDeviationPasses() public {
        guard.delta(key, 1000, 950, MAX_BPS, WINDOW);
    }

    function testNegativeDeviationExceedsReverts() public {
        vm.expectRevert(ICircuitBreakerGuard.ExceedsLimit.selector);
        guard.delta(key, 1000, 949, MAX_BPS, WINDOW);
    }

    function testWindowExpiryResetsAnchor() public {
        guard.delta(key, 1000, 1040, MAX_BPS, WINDOW);

        vm.warp(block.timestamp + WINDOW + 1);

        // New window — anchors to currentValue (2000), not old anchor
        guard.delta(key, 2000, 2090, MAX_BPS, WINDOW);
        (uint128 anchor,) = guard.refs(address(this), key);
        assertEq(anchor, 2000);
    }

    function testWindowExpiryEnforcesNewAnchor() public {
        guard.delta(key, 1000, 1040, MAX_BPS, WINDOW);

        vm.warp(block.timestamp + WINDOW + 1);

        // New window anchored at 2000 — 2101 exceeds 5%
        vm.expectRevert(ICircuitBreakerGuard.ExceedsLimit.selector);
        guard.delta(key, 2000, 2101, MAX_BPS, WINDOW);
    }

    function testMultipleUpdatesWithinWindow() public {
        guard.delta(key, 1000, 1010, MAX_BPS, WINDOW);
        guard.delta(key, 9999, 1020, MAX_BPS, WINDOW); // currentValue ignored
        guard.delta(key, 9999, 1030, MAX_BPS, WINDOW);
        guard.delta(key, 9999, 1050, MAX_BPS, WINDOW); // at boundary

        vm.expectRevert(ICircuitBreakerGuard.ExceedsLimit.selector);
        guard.delta(key, 9999, 1051, MAX_BPS, WINDOW); // beyond boundary
    }

    function testDeltaIsolatesKeys() public {
        bytes32 keyB = keccak256("nav-price");
        guard.delta(key, 1000, 1050, MAX_BPS, WINDOW);
        guard.delta(keyB, 5000, 5250, MAX_BPS, WINDOW);

        (uint128 anchorA,) = guard.refs(address(this), key);
        (uint128 anchorB,) = guard.refs(address(this), keyB);
        assertEq(anchorA, 1000);
        assertEq(anchorB, 5000);
    }

    function testDeltaIsolatesCallers() public {
        guard.delta(key, 1000, 1050, MAX_BPS, WINDOW);
        vm.prank(makeAddr("other"));
        guard.delta(key, 2000, 2100, MAX_BPS, WINDOW);

        (uint128 anchorThis,) = guard.refs(address(this), key);
        (uint128 anchorOther,) = guard.refs(makeAddr("other"), key);
        assertEq(anchorThis, 1000);
        assertEq(anchorOther, 2000);
    }

    function testZeroAnchorAllowsOnlyZero() public {
        // anchor = 0 means maxDelta = 0, so only newValue = 0 passes
        guard.delta(key, 0, 0, MAX_BPS, WINDOW);

        vm.expectRevert(ICircuitBreakerGuard.ExceedsLimit.selector);
        guard.delta(key, 0, 1, MAX_BPS, WINDOW);
    }
}
