// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "src/types/D18.sol";
import "src/libraries/MathLib.sol";

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

    function testFuzzMulInt(uint128 a, uint128 b) public pure {
        vm.assume(uint256(a) * uint256(b) <= type(uint128).max);

        uint128 c = d18(a).mulUint128(b);
        assertEq(c, MathLib.mulDiv(a, b, 1e18));
    }

    function testMulInt() public pure {
        D18 factor = d18(1_500_000_000_000_000_000); // 1.5
        uint128 value = 4_000_000_000_000_000_000;

        assertEq(factor.mulUint128(value), 6_000_000_000_000_000_000);
    }

    function testReciprocalMulInt() public pure {
        D18 divisor = d18(2e18);
        uint128 multiplier = 1e20;

        assertEq(divisor.reciprocalMulInt(multiplier), 5e19);
    }

    function testFuzzReciprocalMulInt(uint128 divisor_, uint128 multiplier) public pure {
        D18 divisor = d18(uint128(bound(divisor_, 1e4, 1e20)));
        multiplier = uint128(bound(multiplier, 0, type(uint128).max / 1e18));

        assertEq(divisor.reciprocalMulInt(multiplier), multiplier * 1e18 / divisor.inner());
    }
}
