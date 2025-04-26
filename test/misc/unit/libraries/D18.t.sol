// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import "src/misc/types/D18.sol";
import "src/misc/libraries/MathLib.sol";

contract D18Test is Test {
    function testFuzzAdd(uint128 a, uint128 b) public pure {
        vm.assume(a <= type(uint128).max / 2);
        vm.assume(b <= type(uint128).max / 2);

        D18 c = d18(a) + d18(b);
        assertEqDecimal(c.inner(), a + b, 18);
    }

    function testFuzzSub(uint128 a, uint128 b) public pure {
        vm.assume(a >= b);

        D18 c = d18(a) - d18(b);
        assertEqDecimal(c.inner(), a - b, 18);
    }

    function testMulUint128() public pure {
        D18 factor = d18(1_500_000_000_000_000_000); // 1.5
        uint128 value = 4_000_000_000_000_000;

        assertEq(factor.mulUint128(value, MathLib.Rounding.Down), 6_000_000_000_000_000);
        assertEq(factor.mulUint128(value, MathLib.Rounding.Up), 6_000_000_000_000_000);
    }

    function testFuzzMulUInt128(uint128 a, uint128 b) public pure {
        a = uint128(bound(a, 1, type(uint128).max));
        b = uint128(bound(b, 0, type(uint128).max / a));

        uint128 cDown = d18(a).mulUint128(b, MathLib.Rounding.Down);
        uint128 cUp = d18(a).mulUint128(b, MathLib.Rounding.Down);
        assertEq(cDown, MathLib.mulDiv(a, b, 1e18));
        assertEq(cUp, MathLib.mulDiv(a, b, 1e18));
    }

    function testRoundingUint128(uint128 a) public pure {
        a = uint128(bound(a, 0, type(uint128).max / 1e18));
        D18 oneHundredPercent = d18(1e18);

        assertEq(oneHundredPercent.mulUint128(a, MathLib.Rounding.Down), a);
        assertEq(oneHundredPercent.mulUint128(a, MathLib.Rounding.Up), a);
    }

    function testMulUint256() public pure {
        D18 factor = d18(1_500_000_000_000_000_000); // 1.5
        uint256 value = 4_000_000_000_000_000_000_000_000;

        assertEq(factor.mulUint256(value, MathLib.Rounding.Down), 6_000_000_000_000_000_000_000_000);
        assertEq(factor.mulUint256(value, MathLib.Rounding.Up), 6_000_000_000_000_000_000_000_000);
    }

    function testFuzzMulUInt256(uint128 a, uint256 b) public pure {
        a = uint128(bound(a, 1, type(uint128).max));
        b = uint256(bound(b, 0, type(uint256).max / a));

        uint256 cDown = d18(a).mulUint256(b, MathLib.Rounding.Down);
        uint256 cUp = d18(a).mulUint256(b, MathLib.Rounding.Down);
        assertEq(cDown, MathLib.mulDiv(a, b, 1e18));
        assertEq(cUp, MathLib.mulDiv(a, b, 1e18));
    }

    function testRoundingUint256(uint256 a) public pure {
        a = bound(a, 0, type(uint256).max / 1e18);
        D18 oneHundredPercent = d18(1e18);

        assertEq(oneHundredPercent.mulUint256(a, MathLib.Rounding.Down), a);
        assertEq(oneHundredPercent.mulUint256(a, MathLib.Rounding.Up), a);
    }

    function testReciprocalMulInt128() public pure {
        D18 divisor = d18(2e18);
        uint128 multiplier = 1e20;

        assertEq(divisor.reciprocalMulUint128(multiplier, MathLib.Rounding.Down), 5e19);
        assertEq(divisor.reciprocalMulUint128(multiplier, MathLib.Rounding.Up), 5e19);
    }

    function testFuzzReciprocalMulInt128(uint128 divisor_, uint128 multiplier) public pure {
        D18 divisor = d18(uint128(bound(divisor_, 1e4, 1e20)));
        multiplier = uint128(bound(multiplier, 0, type(uint128).max / 1e18));

        uint128 expectedDown = multiplier * 1e18 / divisor.inner();
        uint128 expectedUp = (multiplier * 1e18 % divisor.raw()) == 0 ? expectedDown : expectedDown + 1;

        assertEq(divisor.reciprocalMulUint128(multiplier, MathLib.Rounding.Down), expectedDown);
        assertEq(divisor.reciprocalMulUint128(multiplier, MathLib.Rounding.Up), expectedUp);
    }

    function testReciprocalMulInt256() public pure {
        D18 divisor = d18(2e18);
        uint256 multiplier = 1e20;

        assertEq(divisor.reciprocalMulUint256(multiplier, MathLib.Rounding.Down), 5e19);
        assertEq(divisor.reciprocalMulUint256(multiplier, MathLib.Rounding.Up), 5e19);
    }

    function testFuzzReciprocalMulInt256(uint128 divisor_, uint256 multiplier) public pure {
        D18 divisor = d18(uint128(bound(divisor_, 1e4, 1e20)));
        multiplier = bound(multiplier, 0, type(uint256).max / 1e18);

        uint256 expectedDown = multiplier * 1e18 / divisor.inner();
        uint256 expectedUp = (multiplier * 1e18 % divisor.raw()) == 0 ? expectedDown : expectedDown + 1;

        assertEq(divisor.reciprocalMulUint256(multiplier, MathLib.Rounding.Down), expectedDown);
        assertEq(divisor.reciprocalMulUint256(multiplier, MathLib.Rounding.Up), expectedUp);
    }

    function testMulD18() public pure {
        D18 left = d18(50e18);
        D18 right = d18(2e19);

        assertEq(mulD18(left, right).inner(), 100e19);
    }

    function testFuzzMulD18(uint128 left_, uint128 right_) public pure {
        D18 left = d18(uint128(bound(left_, 1, type(uint128).max)));
        D18 right = d18(uint128(bound(right_, 0, type(uint128).max / left.inner())));

        assertEq(mulD18(left, right).inner(), left.inner() * right.inner() / 1e18);
    }

    function testDivD18() public pure {
        D18 numerator = d18(50e18);
        D18 denominator = d18(2e19);

        assertEq(divD18(numerator, denominator).inner(), 25e17);
    }

    function testFuzzDivD18(uint128 numerator_, uint128 denominator_) public pure {
        D18 numerator = d18(uint128(bound(numerator_, 1, 1e20)));
        D18 denominator = d18(uint128(bound(denominator_, 1, 1e20)));

        assertEq(divD18(numerator, denominator).inner(), numerator.inner() * 1e18 / denominator.inner());
    }

    function testEqD18() public pure {
        D18 a = d18(5234);

        assert(eq(a, a));
        assert(!eq(a, d18(5235)));
    }

    function testRawD18() public pure {
        uint128 a_ = 3245252;
        D18 a = d18(a_);

        assertEq(raw(a), a_);
    }
}

contract D18ReciprocalTest is Test {
    /// @dev Fuzz test reciprocal function ensuring accurate calculation and round-trip multiplication.
    function testFuzzReciprocal(uint128 val) public pure {
        // Avoid division-by-zero, keep input reasonable
        val = uint128(bound(val, 1, type(uint128).max / 1e18));
        D18 input = D18.wrap(val);
        D18 result = input.reciprocal();

        uint128 expected = 1e36 / val;
        assertApproxEqAbs(result.inner(), expected, 1, "Reciprocal calculation mismatch");

        D18 roundTrip = input * result;
        uint128 tolerance = 1e3; // very small relative error (~1e-15)
        assertApproxEqAbs(roundTrip.inner(), 1e18, tolerance, "Round-trip multiplication failed");
    }

    /// @dev Explicitly test edge case for reciprocal(1e18) == 1e18
    function testReciprocalOne() public pure {
        D18 one = D18.wrap(1e18);
        D18 result = one.reciprocal();
        assertEq(result.inner(), 1e18, "Reciprocal of 1e18 should be 1e18");
    }

    /// @dev Explicitly test rounding edge cases close to 1
    function testReciprocalRoundingEdges() public pure {
        D18 almostOneUp = D18.wrap(1e18 + 1);
        D18 almostOneDown = D18.wrap(1e18 - 1);

        D18 resultUp = almostOneUp.reciprocal();
        D18 resultDown = almostOneDown.reciprocal();

        assertApproxEqAbs(resultUp.inner(), 1e18 - 1, 1, "Rounding error (upward case)");
        assertApproxEqAbs(resultDown.inner(), 1e18 + 1, 1, "Rounding error (downward case)");
    }
}
