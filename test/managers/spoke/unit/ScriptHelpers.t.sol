// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MathLib} from "../../../../src/misc/libraries/MathLib.sol";

import {ScriptHelpers} from "../../../../src/managers/spoke/ScriptHelpers.sol";
import {IScriptHelpers} from "../../../../src/managers/spoke/interfaces/IScriptHelpers.sol";

import "forge-std/Test.sol";

// ─── Guards ──────────────────────────────────────────────────────────────────

contract ScriptHelpersGuardTest is Test {
    ScriptHelpers helpers;

    function setUp() public {
        helpers = new ScriptHelpers();
    }

    function testRevertIfFalsePasses() public view {
        helpers.revertIfFalse(true);
    }

    function testRevertIfFalseReverts() public {
        vm.expectRevert(IScriptHelpers.ConditionFalse.selector);
        helpers.revertIfFalse(false);
    }

    function testRevertIfTruePasses() public view {
        helpers.revertIfTrue(false);
    }

    function testRevertIfTrueReverts() public {
        vm.expectRevert(IScriptHelpers.ConditionTrue.selector);
        helpers.revertIfTrue(true);
    }
}

// ─── Arithmetic ──────────────────────────────────────────────────────────────

contract ScriptHelpersMathTest is Test {
    ScriptHelpers helpers;

    function setUp() public {
        helpers = new ScriptHelpers();
    }

    function testAdd() public view {
        assertEq(helpers.add(10, 20), 30);
    }

    function testSub() public view {
        assertEq(helpers.sub(100, 42), 58);
    }

    function testSubSaturating() public view {
        assertEq(helpers.subSaturating(100, 42), 58);
        assertEq(helpers.subSaturating(10, 20), 0);
        assertEq(helpers.subSaturating(5, 5), 0);
    }

    function testMul() public view {
        assertEq(helpers.mul(7, 6), 42);
    }

    function testDiv() public view {
        assertEq(helpers.div(100, 3), 33);
    }

    function testMulDivDown() public view {
        assertEq(helpers.mulDiv(2, 3, 4, MathLib.Rounding.Down), 1);
    }

    function testMulDivUp() public view {
        assertEq(helpers.mulDiv(2, 3, 4, MathLib.Rounding.Up), 2);
    }

    function testMulDivUpExact() public view {
        assertEq(helpers.mulDiv(2, 4, 4, MathLib.Rounding.Up), 2);
    }

    function testMulDivLargeValues() public view {
        uint256 a = type(uint128).max;
        assertEq(helpers.mulDiv(a, a, a, MathLib.Rounding.Down), type(uint128).max);
    }

    function testSubBps() public view {
        // 10_000 - 50bps = 99.5%
        assertEq(helpers.subBps(10_000, 50), 9950);
        // 1_000_000 - 100bps = 99%
        assertEq(helpers.subBps(1_000_000, 100), 990_000);
    }

    function testAddBps() public view {
        // 10_000 + 50bps = 100.5%
        assertEq(helpers.addBps(10_000, 50), 10_050);
        // 1_000_000 + 100bps = 101%
        assertEq(helpers.addBps(1_000_000, 100), 1_010_000);
    }

    function testScaleDecimalsUp() public view {
        // 1e6 USDC (6 dec) → 1e18 DAI (18 dec)
        assertEq(helpers.scaleDecimals(1e6, 6, 18, MathLib.Rounding.Down), 1e18);
    }

    function testScaleDecimalsDown() public view {
        // 1e18 DAI (18 dec) → 1e6 USDC (6 dec)
        assertEq(helpers.scaleDecimals(1e18, 18, 6, MathLib.Rounding.Down), 1e6);
    }

    function testScaleDecimalsSame() public view {
        assertEq(helpers.scaleDecimals(42, 18, 18, MathLib.Rounding.Down), 42);
    }

    function testScaleDecimalsRounding() public view {
        // 1.5e6 USDC (6 dec) scaled down to 2 decimals → truncates
        assertEq(helpers.scaleDecimals(1_500_000, 6, 2, MathLib.Rounding.Down), 150);
    }

    function testFuzzAdd(uint128 a, uint128 b) public view {
        assertEq(helpers.add(uint256(a), uint256(b)), uint256(a) + uint256(b));
    }

    function testFuzzMulDiv(uint128 a, uint128 b, uint128 c) public view {
        vm.assume(c > 0);
        assertEq(
            helpers.mulDiv(uint256(a), uint256(b), uint256(c), MathLib.Rounding.Down),
            uint256(a) * uint256(b) / uint256(c)
        );
    }

    function testFuzzSubSaturating(uint256 a, uint256 b) public view {
        uint256 result = helpers.subSaturating(a, b);
        assertEq(result, a >= b ? a - b : 0);
    }

    function testFuzzSubBps(uint128 amount, uint16 bps) public view {
        vm.assume(bps <= 10_000);
        assertEq(helpers.subBps(uint256(amount), uint256(bps)), uint256(amount) * (10_000 - uint256(bps)) / 10_000);
    }
}

// ─── Comparisons ─────────────────────────────────────────────────────────────

contract ScriptHelpersComparisonTest is Test {
    ScriptHelpers helpers;

    function setUp() public {
        helpers = new ScriptHelpers();
    }

    function testEq() public view {
        assertTrue(helpers.eq(42, 42));
        assertFalse(helpers.eq(42, 43));
    }

    function testGt() public view {
        assertTrue(helpers.gt(2, 1));
        assertFalse(helpers.gt(1, 2));
        assertFalse(helpers.gt(1, 1));
    }

    function testLt() public view {
        assertTrue(helpers.lt(1, 2));
        assertFalse(helpers.lt(2, 1));
    }

    function testGte() public view {
        assertTrue(helpers.gte(2, 1));
        assertTrue(helpers.gte(1, 1));
        assertFalse(helpers.gte(0, 1));
    }

    function testLte() public view {
        assertTrue(helpers.lte(1, 2));
        assertTrue(helpers.lte(1, 1));
        assertFalse(helpers.lte(2, 1));
    }

    function testMax() public view {
        assertEq(helpers.max(10, 20), 20);
        assertEq(helpers.max(20, 10), 20);
    }

    function testMin() public view {
        assertEq(helpers.min(10, 20), 10);
        assertEq(helpers.min(20, 10), 10);
    }

    function testClamp() public view {
        assertEq(helpers.clamp(50, 10, 100), 50); // in range
        assertEq(helpers.clamp(5, 10, 100), 10); // below low
        assertEq(helpers.clamp(200, 10, 100), 100); // above high
        assertEq(helpers.clamp(10, 10, 10), 10); // at bounds
    }
}

// ─── Boolean logic ───────────────────────────────────────────────────────────

contract ScriptHelpersBooleanTest is Test {
    ScriptHelpers helpers;

    function setUp() public {
        helpers = new ScriptHelpers();
    }

    function testNot() public view {
        assertTrue(helpers.not(false));
        assertFalse(helpers.not(true));
    }

    function testAnd() public view {
        assertTrue(helpers.and(true, true));
        assertFalse(helpers.and(true, false));
        assertFalse(helpers.and(false, true));
        assertFalse(helpers.and(false, false));
    }

    function testOr() public view {
        assertTrue(helpers.or(true, true));
        assertTrue(helpers.or(true, false));
        assertTrue(helpers.or(false, true));
        assertFalse(helpers.or(false, false));
    }
}

// ─── Branching ───────────────────────────────────────────────────────────────

contract ScriptHelpersTernaryTest is Test {
    ScriptHelpers helpers;

    function setUp() public {
        helpers = new ScriptHelpers();
    }

    function testTernaryUint256True() public view {
        assertEq(helpers.ternary(true, uint256(10), uint256(20)), 10);
    }

    function testTernaryUint256False() public view {
        assertEq(helpers.ternary(false, uint256(10), uint256(20)), 20);
    }

    function testTernaryBytes32True() public view {
        assertEq(helpers.ternary(true, bytes32(uint256(1)), bytes32(uint256(2))), bytes32(uint256(1)));
    }

    function testTernaryBytes32False() public view {
        assertEq(helpers.ternary(false, bytes32(uint256(1)), bytes32(uint256(2))), bytes32(uint256(2)));
    }
}

// ─── Context ─────────────────────────────────────────────────────────────────

contract ScriptHelpersContextTest is Test {
    ScriptHelpers helpers;

    function setUp() public {
        helpers = new ScriptHelpers();
    }

    function testBlockTimestamp() public {
        vm.warp(1700000000);
        assertEq(helpers.blockTimestamp(), 1700000000);
    }

    function testBlockTimestampOffset() public {
        vm.warp(1700000000);
        assertEq(helpers.blockTimestampOffset(300), 1700000300);
    }
}

// ─── ABI decoding ────────────────────────────────────────────────────────────

contract ScriptHelpersTupleTest is Test {
    ScriptHelpers helpers;

    function setUp() public {
        helpers = new ScriptHelpers();
    }

    function testExtractElement() public view {
        bytes memory tuple = abi.encode(uint256(0xbad), uint256(0xdeed), uint256(0xcafe));
        assertEq(helpers.extractElement(tuple, 0), bytes32(uint256(0xbad)));
        assertEq(helpers.extractElement(tuple, 1), bytes32(uint256(0xdeed)));
        assertEq(helpers.extractElement(tuple, 2), bytes32(uint256(0xcafe)));
    }

    function testExtractElementAddress() public {
        address addr = makeAddr("test");
        bytes memory tuple = abi.encode(uint256(42), addr);
        assertEq(helpers.toAddress(helpers.extractElement(tuple, 1)), addr);
    }

    function testExtractElementOutOfBounds() public {
        bytes memory tuple = abi.encode(uint256(1));
        vm.expectRevert();
        helpers.extractElement(tuple, 1);
    }
}

// ─── Type casting ────────────────────────────────────────────────────────────

contract ScriptHelpersCastTest is Test {
    ScriptHelpers helpers;

    function setUp() public {
        helpers = new ScriptHelpers();
    }

    // int256 → uint256
    function testToUint256FromInt() public view {
        assertEq(helpers.toUint256(int256(42)), 42);
        assertEq(helpers.toUint256(int256(0)), 0);
    }

    function testToUint256FromIntNegativeReverts() public {
        vm.expectRevert(IScriptHelpers.CastOverflow.selector);
        helpers.toUint256(int256(-1));
    }

    // uint256 → int256
    function testToInt256() public view {
        assertEq(helpers.toInt256(42), int256(42));
        assertEq(helpers.toInt256(0), int256(0));
    }

    function testToInt256OverflowReverts() public {
        vm.expectRevert(IScriptHelpers.CastOverflow.selector);
        helpers.toInt256(uint256(type(int256).max) + 1);
    }

    // abs
    function testAbs() public view {
        assertEq(helpers.abs(int256(42)), 42);
        assertEq(helpers.abs(int256(-42)), 42);
        assertEq(helpers.abs(int256(0)), 0);
        assertEq(helpers.abs(type(int256).min), uint256(type(int256).max) + 1);
        assertEq(helpers.abs(type(int256).max), uint256(type(int256).max));
    }

    function testAbsFuzz(int256 value) public view {
        uint256 result = helpers.abs(value);
        // Result is always non-negative
        assertTrue(result >= 0);
        // Result matches the magnitude
        if (value >= 0) {
            assertEq(result, uint256(value));
        } else if (value == type(int256).min) {
            assertEq(result, uint256(type(int256).max) + 1);
        } else {
            assertEq(result, uint256(-value));
        }
    }

    // bytes32 ↔ address
    function testToAddress() public view {
        address expected = address(0xdead);
        assertEq(helpers.toAddress(bytes32(uint256(uint160(expected)))), expected);
    }

    function testToBytes32FromAddress() public view {
        address addr = address(0xbeef);
        assertEq(helpers.toBytes32(addr), bytes32(uint256(uint160(addr))));
    }

    // bytes32 ↔ uint256
    function testToUint256FromBytes32() public view {
        assertEq(helpers.toUint256(bytes32(uint256(123))), 123);
    }

    function testToBytes32FromUint256() public view {
        assertEq(helpers.toBytes32(uint256(456)), bytes32(uint256(456)));
    }

    // Roundtrip: extractElement → toAddress
    function testExtractAndCastAddress() public {
        address addr = makeAddr("roundtrip");
        bytes memory tuple = abi.encode(addr);
        bytes32 raw = helpers.extractElement(tuple, 0);
        assertEq(helpers.toAddress(raw), addr);
    }

    // Roundtrip: extractElement → toUint256
    function testExtractAndCastUint256() public view {
        bytes memory tuple = abi.encode(uint256(999));
        bytes32 raw = helpers.extractElement(tuple, 0);
        assertEq(helpers.toUint256(raw), 999);
    }
}
