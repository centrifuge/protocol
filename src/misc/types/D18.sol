// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

// Small library to handle fixed point number operations with 18 decimals with static typing support.

import {MathLib} from "../libraries/MathLib.sol";

type D18 is uint128;

using MathLib for uint256;

/// @dev add two D18 types
function add(D18 d1, D18 d2) pure returns (D18) {
    return D18.wrap(D18.unwrap(d1) + D18.unwrap(d2));
}

/// @dev subtract two D18 types
function sub(D18 d1, D18 d2) pure returns (D18) {
    return D18.wrap(D18.unwrap(d1) - D18.unwrap(d2));
}

/// @dev Divides one D18 by another one while retaining precision:
/// - nominator (decimal): 50e18
/// - denominator (decimal):  2e19
/// - result (decimal): 25e17
function divD18(D18 d1, D18 d2) pure returns (D18) {
    return D18.wrap(MathLib.mulDiv(D18.unwrap(d1), 1e18, D18.unwrap(d2)).toUint128());
}

/// @dev Multiplies one D18 with another one while retaining precision:
/// - value1 (decimal): 50e18
/// - value2 (decimal):  2e19
/// - result (decimal): 100e19
function mulD18(D18 d1, D18 d2) pure returns (D18) {
    return D18.wrap(MathLib.mulDiv(D18.unwrap(d1), D18.unwrap(d2), 1e18).toUint128());
}

/// @dev Returns the reciprocal of a D18 decimal, i.e. 1 / d.
///      Example: if d = 2.0 (2e18 internally), reciprocal(d) = 0.5 (5e17 internally).
function reciprocal(D18 d) pure returns (D18) {
    uint128 val = D18.unwrap(d);
    require(val != 0, "D18/division-by-zero");
    return d18(1e18, val);
}

/// @dev Multiplies a decimal by an integer. i.e:
/// - d (decimal):      1_500_000_000_000_000_000
/// - value (integer):  4_000_000_000_000_000_000
/// - result (integer): 6_000_000_000_000_000_000
function mulUint128(D18 d, uint128 value, MathLib.Rounding rounding) pure returns (uint128) {
    return MathLib.mulDiv(D18.unwrap(d), value, 1e18, rounding).toUint128();
}

/// @dev Multiplies a decimal by an integer. i.e:
/// - d (decimal):      1_500_000_000_000_000_000
/// - value (integer):  4_000_000_000_000_000_000
/// - result (integer): 6_000_000_000_000_000_000
function mulUint256(D18 d, uint256 value, MathLib.Rounding rounding) pure returns (uint256) {
    return MathLib.mulDiv(D18.unwrap(d), value, 1e18, rounding);
}

/// @dev  Divides an integer by a decimal, i.e.
/// @dev  Same as mulDiv for integers, i.e:
/// - d (decimal):      2_000_000_000_000_000_000
/// - value (integer):  100_000_000_000_000_000_000
/// - result (integer): 50_000_000_000_000_000_000
function reciprocalMulUint128(D18 d, uint128 value, MathLib.Rounding rounding) pure returns (uint128) {
    return MathLib.mulDiv(value, 1e18, d.raw(), rounding).toUint128();
}

/// @dev  Divides an integer by a decimal, i.e.
/// @dev  Same as mulDiv for integers, i.e:
/// - d (decimal):      2_000_000_000_000_000_000
/// - value (integer):  100_000_000_000_000_000_000
/// - result (integer): 50_000_000_000_000_000_000
function reciprocalMulUint256(D18 d, uint256 value, MathLib.Rounding rounding) pure returns (uint256) {
    return MathLib.mulDiv(value, 1e18, d.raw(), rounding);
}

/// @dev Easy way to construct a decimal number
function d18(uint128 value) pure returns (D18) {
    return D18.wrap(value);
}

/// @dev Easy way to construct a decimal number
function d18(uint128 num, uint128 den) pure returns (D18) {
    return D18.wrap(MathLib.mulDiv(num, 1e18, den).toUint128());
}

function eq(D18 a, D18 b) pure returns (bool) {
    return D18.unwrap(a) == D18.unwrap(b);
}

function isZero(D18 a) pure returns (bool) {
    return D18.unwrap(a) == 0;
}

function isNotZero(D18 a) pure returns (bool) {
    return D18.unwrap(a) != 0;
}

function raw(D18 d) pure returns (uint128) {
    return D18.unwrap(d);
}

using {
    add as +,
    sub as -,
    divD18 as /,
    eq,
    mulD18 as *,
    mulUint128,
    mulUint256,
    reciprocalMulUint128,
    reciprocalMulUint256,
    reciprocal,
    raw,
    isZero,
    isNotZero
} for D18 global;
