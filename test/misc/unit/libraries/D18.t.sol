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
        uint128 value = 4_000_000_000_000_000_000;

        assertEq(factor.mulUint128(value), 6_000_000_000_000_000_000);
    }

    function testFuzzMulUInt128(uint128 a, uint128 b) public pure {
        a = uint128(bound(a, 1, type(uint128).max));
        b = uint128(bound(b, 0, type(uint128).max / a));

        uint128 c = d18(a).mulUint128(b);
        assertEq(c, MathLib.mulDiv(a, b, 1e18));
    }

    function testRoundingUint128(uint128 a) public pure {
        a = uint128(bound(a, 0, type(uint128).max / 1e18));
        D18 oneHundredPercent = d18(1e18);

        assertEq(oneHundredPercent.mulUint128(a), a);
    }

    function testMulUint256() public pure {
        D18 factor = d18(1_500_000_000_000_000_000); // 1.5
        uint256 value = 4_000_000_000_000_000_000_000_000;

        assertEq(factor.mulUint256(value), 6_000_000_000_000_000_000_000_000);
    }

    function testFuzzMulUInt256(uint128 a, uint256 b) public pure {
        a = uint128(bound(a, 1, type(uint128).max));
        b = uint256(bound(b, 0, type(uint256).max / a));

        uint256 c = d18(a).mulUint256(b);
        assertEq(c, MathLib.mulDiv(a, b, 1e18));
    }

    function testRoundingUint256(uint256 a) public pure {
        a = bound(a, 0, type(uint256).max / 1e18);
        D18 oneHundredPercent = d18(1e18);

        assertEq(oneHundredPercent.mulUint256(a), a);
    }

    function testReciprocalMulInt128() public pure {
        D18 divisor = d18(2e18);
        uint128 multiplier = 1e20;

        assertEq(divisor.reciprocalMulUint128(multiplier), 5e19);
    }

    function testFuzzReciprocalMulInt128(uint128 divisor_, uint128 multiplier) public pure {
        D18 divisor = d18(uint128(bound(divisor_, 1e4, 1e20)));
        multiplier = uint128(bound(multiplier, 0, type(uint128).max / 1e18));

        assertEq(divisor.reciprocalMulUint128(multiplier), multiplier * 1e18 / divisor.inner());
    }

    function testReciprocalMulInt256() public pure {
        D18 divisor = d18(2e18);
        uint256 multiplier = 1e20;

        assertEq(divisor.reciprocalMulUint256(multiplier), 5e19);
    }

    function testFuzzReciprocalMulInt256(uint128 divisor_, uint256 multiplier) public pure {
        D18 divisor = d18(uint128(bound(divisor_, 1e4, 1e20)));
        multiplier = bound(multiplier, 0, type(uint256).max / 1e18);

        assertEq(divisor.reciprocalMulUint256(multiplier), multiplier * 1e18 / divisor.inner());
    }

    function testMulD8() public pure {
        D18 left = d18(50e18);
        D18 right = d18(2e19);

        assertEq(mulD8(left, right).inner(), 100e19);
    }

    function testFuzzMulD8(uint128 left_, uint128 right_) public pure {
        D18 left = d18(uint128(bound(left_, 1, type(uint128).max)));
        D18 right = d18(uint128(bound(right_, 0, type(uint128).max / left.inner())));

        assertEq(mulD8(left, right).inner(), left.inner() * right.inner() / 1e18);
    }

    function testDivD8() public pure {
        D18 numerator = d18(50e18);
        D18 denominator = d18(2e19);

        assertEq(divD8(numerator, denominator).inner(), 25e17);
    }

    function testFuzzDivD8(uint128 numerator_, uint128 denominator_) public pure {
        D18 numerator = d18(uint128(bound(numerator_, 1, 1e20)));
        D18 denominator = d18(uint128(bound(denominator_, 1, 1e20)));

        assertEq(divD8(numerator, denominator).inner(), numerator.inner() * 1e18 / denominator.inner());
    }
}
