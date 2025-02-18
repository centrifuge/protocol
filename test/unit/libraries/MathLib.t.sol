// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "src/interfaces/IERC20.sol";
import {MathLib} from "src/libraries/MathLib.sol";

/// @author Modified from https://github.com/morpho-org/morpho-blue/blob/main/test/forge/libraries/MathLibTest.sol
contract MathLibTest is Test {
    using MathLib for uint256;

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
        vm.assume(x > 0 && y > 0);

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
        vm.assume(x > 0);
        vm.expectRevert("MathLib/uint128-overflow");
        MathLib.toUint128(uint256(type(uint128).max) + x);
    }

    function testToUint8(uint256 x) public pure {
        x = bound(x, 0, type(uint8).max);

        assertEq(x, uint256(MathLib.toUint8(x)));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testToUint8Overflow(uint256 x) public {
        vm.assume(x > type(uint8).max);
        vm.expectRevert("MathLib/uint8-overflow");
        MathLib.toUint8(x);
    }
}
