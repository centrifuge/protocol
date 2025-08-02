// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import "../../../../src/misc/libraries/MathLib.sol";

import "forge-std/Test.sol";

contract MathLibTest is Test {
    using MathLib for uint256;

    function testSymbolicRpow() public pure {
        uint256 base = 10 ** 27;
        uint256 x = 2 * 10 ** 27;
        uint256 n = 3;

        uint256 result = MathLib.rpow(x, n, base);
        uint256 expected = 8 * 10 ** 27; // 2^3 = 8, scaled by base

        assertEq(result, expected, "Incorrect rpow calculation");
    }

    function testSymbolicMulDivDown(uint256 x, uint256 y, uint256 denominator) public pure {
        // Ignore cases where x * y overflows or denominator is 0.
        unchecked {
            if (denominator == 0 || (x != 0 && (x * y) / x != y)) return;
        }

        assertEq(MathLib.mulDiv(x, y, denominator, MathLib.Rounding.Down), (x * y) / denominator);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testSymbolicMulDivDownZeroDenominator(uint256 x, uint256 y) public {
        vm.expectRevert();
        MathLib.mulDiv(x, y, 0, MathLib.Rounding.Down);
    }

    function testSymbolicMulDivUp(uint256 x, uint256 y, uint256 denominator) public pure {
        denominator = bound(denominator, 1, type(uint256).max - 1);
        y = bound(y, 1, type(uint256).max);
        x = bound(x, 0, (type(uint256).max - denominator - 1) / y);

        assertEq(MathLib.mulDiv(x, y, denominator, MathLib.Rounding.Up), x * y == 0 ? 0 : (x * y - 1) / denominator + 1);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testSymbolicMulDivUpUnderverflow(uint256 x, uint256 y) public {
        vm.assume(x > 0 && y > 0);

        vm.expectRevert();
        MathLib.mulDiv(x, y, 0, MathLib.Rounding.Up);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testSymbolicMulDivUpZeroDenominator(uint256 x, uint256 y) public {
        vm.expectRevert();
        MathLib.mulDiv(x, y, 0, MathLib.Rounding.Up);
    }

    function testToUint128(uint256 x) public pure {
        x = bound(x, 0, type(uint128).max);

        assertEq(x, uint256(MathLib.toUint128(x)));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testSymbolicToUint128Overflow(uint128 x) public {
        vm.assume(x > 0);
        vm.expectRevert(MathLib.Uint128_Overflow.selector);
        MathLib.toUint128(uint256(type(uint128).max) + x);
    }

    function testToUint8(uint256 x) public pure {
        x = bound(x, 0, type(uint8).max);

        assertEq(x, uint256(MathLib.toUint8(x)));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testSymbolicToUint8Overflow(uint256 x) public {
        vm.assume(x > type(uint8).max);
        vm.expectRevert(MathLib.Uint8_Overflow.selector);
        MathLib.toUint8(x);
    }

    function testSymbolicToUint32(uint256 x) public pure {
        x = bound(x, 0, type(uint32).max);

        assertEq(x, uint256(MathLib.toUint32(x)));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testSymbolicToUint32Overflow(uint256 x) public {
        vm.assume(x > type(uint32).max);
        vm.expectRevert(MathLib.Uint32_Overflow.selector);
        MathLib.toUint32(x);
    }

    function testSymbolicToUint64(uint256 x) public pure {
        x = bound(x, 0, type(uint64).max);

        assertEq(x, uint256(MathLib.toUint64(x)));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testSymbolicToUint64Overflow(uint256 x) public {
        vm.assume(x > type(uint64).max);
        vm.expectRevert(MathLib.Uint64_Overflow.selector);
        MathLib.toUint64(x);
    }

    function testSymbolicMin(uint256 x, uint256 y) public pure {
        vm.assume(x > 0);
        y = uint256(bound(y, 0, x - 1));
        assertEq(MathLib.min(x, y), y);
    }

    function testSymbolicMax(uint256 x, uint256 y) public pure {
        vm.assume(x > 0);
        y = uint256(bound(y, 0, x - 1));
        assertEq(MathLib.max(x, y), x);
    }
}
