// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "src/libraries/D18.sol";
import "src/libraries/MathLib.sol";

contract TestPortfolio is Test {
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

        uint128 c = d18(a).mulInt(b);
        assertEq(c, MathLib.mulDiv(a, b, 1e18));
    }

    function testMulInt() public pure {
        D18 factor = d18(1_500_000_000_000_000_000); // 1.5
        uint128 value = 4_000_000_000_000_000_000;

        assertEq(factor.mulInt(value), 6_000_000_000_000_000_000);
    }
}
