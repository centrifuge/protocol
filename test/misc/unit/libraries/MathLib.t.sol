// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {MathLib} from "../../../../src/misc/libraries/MathLib.sol";

import "forge-std/Test.sol";

contract MathLibTest is Test {
    using MathLib for uint256;

    function testRpow() public pure {
        uint256 base = 10 ** 27;
        uint256 x = 2 * 10 ** 27;
        uint256 n = 3;

        uint256 result = MathLib.rpow(x, n, base);
        uint256 expected = 8 * 10 ** 27; // 2^3 = 8, scaled by base

        assertEq(result, expected, "Incorrect rpow calculation");
    }

    function testRpowZeroBaseZeroExp() public pure {
        assertEq(MathLib.rpow(0, 0, 5), 5, "0^0 should return base");
    }

    function testRpowZeroBasePositiveExp() public pure {
        assertEq(MathLib.rpow(0, 3, 10 ** 27), 0, "0^n (n>0) should be 0");
    }

    function testMulDivDown(uint256 x, uint256 y, uint256 denominator) public pure {
        // Ignore cases where x * y overflows or denominator is 0.
        unchecked {
            if (denominator == 0 || (x != 0 && (x * y) / x != y)) return;
        }

        assertEq(MathLib.mulDiv(x, y, denominator, MathLib.Rounding.Down), (x * y) / denominator);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testMulDivDownZeroDenominator(uint256 x, uint256 y) public {
        vm.expectRevert();
        MathLib.mulDiv(x, y, 0, MathLib.Rounding.Down);
    }

    function testMulDivUp(uint256 x, uint256 y, uint256 denominator) public pure {
        denominator = bound(denominator, 1, type(uint256).max - 1);
        y = bound(y, 1, type(uint256).max);
        x = bound(x, 0, (type(uint256).max - denominator - 1) / y);

        assertEq(MathLib.mulDiv(x, y, denominator, MathLib.Rounding.Up), x * y == 0 ? 0 : (x * y - 1) / denominator + 1);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testMulDivUpUnderverflow(uint256 x, uint256 y) public {
        x = bound(x, 1, type(uint256).max);
        y = bound(y, 1, type(uint256).max);

        vm.expectRevert();
        MathLib.mulDiv(x, y, 0, MathLib.Rounding.Up);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testMulDivUpZeroDenominator(uint256 x, uint256 y) public {
        vm.expectRevert();
        MathLib.mulDiv(x, y, 0, MathLib.Rounding.Up);
    }

    function testToUint128(uint256 x) public pure {
        x = bound(x, 0, type(uint128).max);

        assertEq(x, uint256(MathLib.toUint128(x)));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testToUint128Overflow(uint128 x) public {
        x = uint128(bound(x, 1, type(uint128).max));
        vm.expectRevert(MathLib.Uint128_Overflow.selector);
        MathLib.toUint128(uint256(type(uint128).max) + x);
    }

    function testToUint8(uint256 x) public pure {
        x = bound(x, 0, type(uint8).max);

        assertEq(x, uint256(MathLib.toUint8(x)));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testToUint8Overflow(uint256 x) public {
        x = bound(x, uint256(type(uint8).max) + 1, type(uint256).max);
        vm.expectRevert(MathLib.Uint8_Overflow.selector);
        MathLib.toUint8(x);
    }

    function testToUint16(uint256 x) public pure {
        x = bound(x, 0, type(uint16).max);

        assertEq(x, uint256(MathLib.toUint16(x)));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testToUint16Overflow(uint256 x) public {
        x = bound(x, uint256(type(uint16).max) + 1, type(uint256).max);
        vm.expectRevert(MathLib.Uint16_Overflow.selector);
        MathLib.toUint16(x);
    }

    function testToUint32(uint256 x) public pure {
        x = bound(x, 0, type(uint32).max);

        assertEq(x, uint256(MathLib.toUint32(x)));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testToUint32Overflow(uint256 x) public {
        x = bound(x, uint256(type(uint32).max) + 1, type(uint256).max);

        vm.expectRevert(MathLib.Uint32_Overflow.selector);
        MathLib.toUint32(x);
    }

    function testToUint64(uint256 x) public pure {
        x = bound(x, 0, type(uint64).max);

        assertEq(x, uint256(MathLib.toUint64(x)));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testToUint64Overflow(uint256 x) public {
        x = bound(x, uint256(type(uint64).max) + 1, type(uint256).max);

        vm.expectRevert(MathLib.Uint64_Overflow.selector);
        MathLib.toUint64(x);
    }

    function testToUint96(uint256 x) public pure {
        x = bound(x, 0, type(uint96).max);

        assertEq(x, uint256(MathLib.toUint96(x)));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testToUint96Overflow(uint256 x) public {
        x = bound(x, uint256(type(uint96).max) + 1, type(uint256).max);

        vm.expectRevert(MathLib.Uint96_Overflow.selector);
        MathLib.toUint96(x);
    }

    function testMin(uint256 x, uint256 y) public pure {
        x = bound(x, 1, type(uint256).max);

        y = uint256(bound(y, 0, x - 1));
        assertEq(MathLib.min(x, y), y);
    }

    function testMax(uint256 x, uint256 y) public pure {
        x = bound(x, 1, type(uint256).max);

        y = uint256(bound(y, 0, x - 1));
        assertEq(MathLib.max(x, y), x);
    }

    function testAbsDiff() public pure {
        assertEq(MathLib.absDiff(0, 0), 0);
        assertEq(MathLib.absDiff(5, 5), 0);
        assertEq(MathLib.absDiff(7, 3), 4);
        assertEq(MathLib.absDiff(3, 7), 4);
    }

    function testFuzzAbsDiff(uint256 a, uint256 b) public pure {
        assertEq(MathLib.absDiff(a, b), MathLib.absDiff(b, a));
        assertEq(MathLib.absDiff(a, b), a > b ? a - b : b - a);
    }

    function testToInt128(uint256 x) public pure {
        x = bound(x, 0, uint128(type(int128).max));

        assertEq(uint256(int256(MathLib.toInt128(x))), x);
    }

    function testToInt128Boundary() public pure {
        assertEq(MathLib.toInt128(0), 0);
        assertEq(MathLib.toInt128(uint128(type(int128).max)), type(int128).max);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testToInt128Overflow(uint256 x) public {
        x = bound(x, uint256(uint128(type(int128).max)) + 1, type(uint256).max);
        vm.expectRevert(MathLib.Int128_Overflow.selector);
        MathLib.toInt128(x);
    }

    function testFuzzSaturatingAdd(uint128 a, uint128 b) public pure {
        uint256 sum = uint256(a) + b;
        assertEq(MathLib.saturatingAdd(a, b), sum > type(uint128).max ? type(uint128).max : sum);
    }

    function testSaturatingSub() public pure {
        assertEq(MathLib.saturatingSub(7, 3), 4);
        assertEq(MathLib.saturatingSub(3, 3), 0);
        assertEq(MathLib.saturatingSub(3, 7), 0);
        assertEq(MathLib.saturatingSub(0, type(uint128).max), 0);
        assertEq(MathLib.saturatingSub(type(uint128).max, 0), type(uint128).max);
    }

    function testFuzzSaturatingSub(uint128 a, uint128 b) public pure {
        uint128 diff = MathLib.saturatingSub(a, b);

        assertEq(diff, a > b ? a - b : 0);
        assertLe(diff, a);
        assertEq(uint256(diff) + MathLib.min(a, b), a, "the result and the subtrahend recompose the minuend");
    }

    function testFractionOfMatchesMulDiv(uint128 value, uint128 part, uint128 total) public pure {
        total = uint128(bound(total, 1, type(uint128).max));
        part = uint128(bound(part, 0, total));

        assertEq(uint256(value).fractionOf(part, total, MathLib.Rounding.Down), MathLib.mulDiv(value, part, total));
        uint256 down = uint256(value).fractionOf(part, total, MathLib.Rounding.Down);
        uint256 up = uint256(value).fractionOf(part, total, MathLib.Rounding.Up);
        assertTrue(up == down || up == down + 1, "up is down or one more");
        assertLe(down, value, "a part of the total never exceeds the value");
    }

    /// @dev The whole of a total is exactly the value, whichever way it rounds, so no remainder is stranded
    function testFractionOfTheWholeIsTheValue(uint128 value, uint128 total) public pure {
        total = uint128(bound(total, 1, type(uint128).max));

        assertEq(uint256(value).fractionOf(total, total, MathLib.Rounding.Down), value);
        assertEq(uint256(value).fractionOf(total, total, MathLib.Rounding.Up), value);
    }

    /// @dev A zero part is zero even against a zero total, which `mulDiv` alone would revert on
    function testFractionOfNothingIsZero(uint128 value) public pure {
        assertEq(uint256(value).fractionOf(0, 0, MathLib.Rounding.Down), 0);
        assertEq(uint256(value).fractionOf(0, 0, MathLib.Rounding.Up), 0);
    }

    function testFractionOfRounds() public pure {
        assertEq(uint256(10).fractionOf(1, 3, MathLib.Rounding.Down), 3);
        assertEq(uint256(10).fractionOf(1, 3, MathLib.Rounding.Up), 4);
        assertEq(uint256(10).fractionOf(2, 3, MathLib.Rounding.Down), 6);
        assertEq(uint256(10).fractionOf(2, 3, MathLib.Rounding.Up), 7);
    }
}
