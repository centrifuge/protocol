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
        (uint128 total,) = guard.cumulative(address(this), key, WINDOW);
        assertEq(total, 500_000e6);
    }

    function testMultipleTalliesAccumulate() public {
        guard.tally(key, 300_000e6, MAX, WINDOW);
        guard.tally(key, 400_000e6, MAX, WINDOW);
        (uint128 total,) = guard.cumulative(address(this), key, WINDOW);
        assertEq(total, 700_000e6);
    }

    function testTallyExactLimitPasses() public {
        guard.tally(key, MAX, MAX, WINDOW);
        (uint128 total,) = guard.cumulative(address(this), key, WINDOW);
        assertEq(total, MAX);
    }

    function testTallyExceedsLimitReverts() public {
        guard.tally(key, 600_000e6, MAX, WINDOW);
        vm.expectRevert(
            abi.encodeWithSelector(ICircuitBreakerGuard.ExceedsCumulativeLimit.selector, key, 500_000e6, MAX, WINDOW)
        );
        guard.tally(key, 500_000e6, MAX, WINDOW);
    }

    function testTallyResetsAfterWindowExpiry() public {
        guard.tally(key, 900_000e6, MAX, WINDOW);
        vm.warp(block.timestamp + WINDOW + 1);
        guard.tally(key, 900_000e6, MAX, WINDOW);
        (uint128 total,) = guard.cumulative(address(this), key, WINDOW);
        assertEq(total, 900_000e6);
    }

    function testTallyDoesNotResetBeforeWindowExpiry() public {
        guard.tally(key, 600_000e6, MAX, WINDOW);
        vm.warp(block.timestamp + WINDOW - 1);
        vm.expectRevert(
            abi.encodeWithSelector(ICircuitBreakerGuard.ExceedsCumulativeLimit.selector, key, 500_000e6, MAX, WINDOW)
        );
        guard.tally(key, 500_000e6, MAX, WINDOW);
    }

    function testTallyIsolatesKeys() public {
        bytes32 keyB = keccak256("bridge-weth");
        guard.tally(key, 900_000e6, MAX, WINDOW);
        guard.tally(keyB, 900_000e6, MAX, WINDOW);
        (uint128 totalA,) = guard.cumulative(address(this), key, WINDOW);
        (uint128 totalB,) = guard.cumulative(address(this), keyB, WINDOW);
        assertEq(totalA, 900_000e6);
        assertEq(totalB, 900_000e6);
    }

    function testTallyIsolatesCallers() public {
        guard.tally(key, 900_000e6, MAX, WINDOW);
        vm.prank(makeAddr("other"));
        guard.tally(key, 900_000e6, MAX, WINDOW);
        (uint128 totalThis,) = guard.cumulative(address(this), key, WINDOW);
        (uint128 totalOther,) = guard.cumulative(makeAddr("other"), key, WINDOW);
        assertEq(totalThis, 900_000e6);
        assertEq(totalOther, 900_000e6);
    }

    function testFuzzTallyAccumulation(uint128 a, uint128 b) public {
        uint256 max = type(uint128).max;
        guard.tally(key, a, max, WINDOW);
        if (uint256(a) + uint256(b) > max) {
            vm.expectRevert(
                abi.encodeWithSelector(ICircuitBreakerGuard.ExceedsCumulativeLimit.selector, key, b, max, WINDOW)
            );
            guard.tally(key, b, max, WINDOW);
        } else {
            guard.tally(key, b, max, WINDOW);
            (uint128 total,) = guard.cumulative(address(this), key, WINDOW);
            assertEq(total, uint256(a) + uint256(b));
        }
    }

    function testTallyWindowZeroResetsEveryBlock() public {
        // window=0: first call opens a window anchored at block.timestamp
        guard.tally(key, MAX, MAX, 0);

        // Same block: 0 seconds elapsed, not > 0, so amounts accumulate and revert
        vm.expectRevert(abi.encodeWithSelector(ICircuitBreakerGuard.ExceedsCumulativeLimit.selector, key, 1, MAX, 0));
        guard.tally(key, 1, MAX, 0);

        // Next block: 1 second elapsed > 0, window resets
        vm.warp(block.timestamp + 1);
        guard.tally(key, MAX, MAX, 0);
        (uint128 total,) = guard.cumulative(address(this), key, 0);
        assertEq(total, MAX);
    }

    function testTallyTruncationReverts() public {
        // amount > uint128 max: toUint128 reverts even if limit check passes
        uint256 amount = uint256(type(uint128).max) + 1;
        vm.expectRevert();
        guard.tally(key, amount, type(uint256).max, WINDOW);
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
        (uint128 anchor, uint64 windowStart) = guard.refs(address(this), key, WINDOW);
        assertEq(anchor, 1000);
        assertEq(windowStart, block.timestamp);
    }

    function testWithinWindowUsesStoredAnchor() public {
        guard.delta(key, 1000, 1020, MAX_BPS, WINDOW);

        // Second call within window — currentValue is ignored, anchor stays 1000
        guard.delta(key, 9999, 1049, MAX_BPS, WINDOW);
        (uint128 anchor,) = guard.refs(address(this), key, WINDOW);
        assertEq(anchor, 1000);
    }

    function testExactBoundaryPasses() public {
        // 5% of 1000 = 50, so 1050 should pass
        guard.delta(key, 1000, 1050, MAX_BPS, WINDOW);
    }

    function testExceedsBoundaryReverts() public {
        // 5% of 1000 = 50, so 1051 should fail
        vm.expectRevert(
            abi.encodeWithSelector(ICircuitBreakerGuard.ExceedsDeltaLimit.selector, key, 1000, 1051, MAX_BPS, WINDOW)
        );
        guard.delta(key, 1000, 1051, MAX_BPS, WINDOW);
    }

    function testNegativeDeviationPasses() public {
        guard.delta(key, 1000, 950, MAX_BPS, WINDOW);
    }

    function testNegativeDeviationExceedsReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ICircuitBreakerGuard.ExceedsDeltaLimit.selector, key, 1000, 949, MAX_BPS, WINDOW)
        );
        guard.delta(key, 1000, 949, MAX_BPS, WINDOW);
    }

    function testWindowExpiryResetsAnchor() public {
        guard.delta(key, 1000, 1040, MAX_BPS, WINDOW);

        vm.warp(block.timestamp + WINDOW + 1);

        // New window — anchors to currentValue (2000), not old anchor
        guard.delta(key, 2000, 2090, MAX_BPS, WINDOW);
        (uint128 anchor,) = guard.refs(address(this), key, WINDOW);
        assertEq(anchor, 2000);
    }

    function testWindowExpiryEnforcesNewAnchor() public {
        guard.delta(key, 1000, 1040, MAX_BPS, WINDOW);

        vm.warp(block.timestamp + WINDOW + 1);

        // New window anchored at 2000 — 2101 exceeds 5%
        vm.expectRevert(
            abi.encodeWithSelector(ICircuitBreakerGuard.ExceedsDeltaLimit.selector, key, 2000, 2101, MAX_BPS, WINDOW)
        );
        guard.delta(key, 2000, 2101, MAX_BPS, WINDOW);
    }

    function testMultipleUpdatesWithinWindow() public {
        guard.delta(key, 1000, 1010, MAX_BPS, WINDOW);
        guard.delta(key, 9999, 1020, MAX_BPS, WINDOW); // currentValue ignored
        guard.delta(key, 9999, 1030, MAX_BPS, WINDOW);
        guard.delta(key, 9999, 1050, MAX_BPS, WINDOW); // at boundary

        vm.expectRevert(
            abi.encodeWithSelector(ICircuitBreakerGuard.ExceedsDeltaLimit.selector, key, 9999, 1051, MAX_BPS, WINDOW)
        );
        guard.delta(key, 9999, 1051, MAX_BPS, WINDOW); // beyond boundary
    }

    function testDeltaIsolatesKeys() public {
        bytes32 keyB = keccak256("nav-price");
        guard.delta(key, 1000, 1050, MAX_BPS, WINDOW);
        guard.delta(keyB, 5000, 5250, MAX_BPS, WINDOW);

        (uint128 anchorA,) = guard.refs(address(this), key, WINDOW);
        (uint128 anchorB,) = guard.refs(address(this), keyB, WINDOW);
        assertEq(anchorA, 1000);
        assertEq(anchorB, 5000);
    }

    function testDeltaIsolatesCallers() public {
        guard.delta(key, 1000, 1050, MAX_BPS, WINDOW);
        vm.prank(makeAddr("other"));
        guard.delta(key, 2000, 2100, MAX_BPS, WINDOW);

        (uint128 anchorThis,) = guard.refs(address(this), key, WINDOW);
        (uint128 anchorOther,) = guard.refs(makeAddr("other"), key, WINDOW);
        assertEq(anchorThis, 1000);
        assertEq(anchorOther, 2000);
    }

    function testZeroCurrentValueSkipsValidation() public {
        // currentValue == 0 skips validation entirely — no anchor is set, no revert
        guard.delta(key, 0, 0, MAX_BPS, WINDOW);
        guard.delta(key, 0, 1_000_000, MAX_BPS, WINDOW); // no revert even with huge deviation
        (uint128 anchor, uint64 windowStart) = guard.refs(address(this), key, WINDOW);
        assertEq(anchor, 0);
        assertEq(windowStart, 0);
    }

    function testDeltaMaxBpsZeroAllowsOnlyExactMatch() public {
        // maxDeltaBps=0: d*10_000 <= 0 only when d == 0, i.e. newValue == anchor
        guard.delta(key, 1000, 1000, 0, WINDOW);

        vm.expectRevert(
            abi.encodeWithSelector(ICircuitBreakerGuard.ExceedsDeltaLimit.selector, key, 9999, 1001, 0, WINDOW)
        );
        guard.delta(key, 9999, 1001, 0, WINDOW); // any deviation from anchor (1000) fails
    }

    function testDeltaWindowZeroResetsEveryBlock() public {
        // window=0: anchor resets on every new block (1 second elapsed > 0)
        vm.warp(1_000_000);
        guard.delta(key, 1000, 1000, MAX_BPS, 0);
        (uint128 anchor1,) = guard.refs(address(this), key, 0);
        assertEq(anchor1, 1000);

        vm.warp(block.timestamp + 1);
        guard.delta(key, 2000, 2000, MAX_BPS, 0);
        (uint128 anchor2,) = guard.refs(address(this), key, 0);
        assertEq(anchor2, 2000);
    }

    function testFuzzDelta(uint128 currentValue, uint128 newValue, uint16 maxDeltaBps) public {
        vm.assume(currentValue > 0);
        vm.warp(1_000_000); // ensure windowStart=0 triggers new window

        uint256 d = newValue > currentValue ? uint256(newValue) - currentValue : uint256(currentValue) - newValue;
        if (d * 10_000 > uint256(currentValue) * maxDeltaBps) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ICircuitBreakerGuard.ExceedsDeltaLimit.selector, key, currentValue, newValue, maxDeltaBps, WINDOW
                )
            );
            guard.delta(key, currentValue, newValue, maxDeltaBps, WINDOW);
        } else {
            guard.delta(key, currentValue, newValue, maxDeltaBps, WINDOW);
            (uint128 anchor,) = guard.refs(address(this), key, WINDOW);
            assertEq(anchor, currentValue);
        }
    }
}
