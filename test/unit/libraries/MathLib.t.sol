// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "src/libraries/MathLib.sol";

contract TestMath is Test {
    // TODO(@wischli): Fuzzing
    function testRpow() public pure {
        uint256 base = 10 ** 27;
        uint256 x = 2 * 10 ** 27;
        uint256 n = 3;

        uint256 result = MathLib.rpow(x, n, base);
        uint256 expected = 8 * 10 ** 27; // 2^3 = 8, scaled by base

        assertEq(result, expected, "Incorrect rpow calculation");
    }
}
