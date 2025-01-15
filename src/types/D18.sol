// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

// Small library to handle fixed point number operations with 18 decimals with static typing support.

import {MathLib} from "src/libraries/MathLib.sol";

type D18 is uint128;

using MathLib for uint256;

/// @dev add two D18 types
function add(D18 d1, D18 d2) pure returns (D18) {
    return D18.wrap(D18.unwrap(d1) + D18.unwrap(d2));
}

/// @dev substract two D18 types
function sub(D18 d1, D18 d2) pure returns (D18) {
    return D18.wrap(D18.unwrap(d1) - D18.unwrap(d2));
}

/// @dev Divides one D18 by another one while retaining precision:
/// - nominator (decimal): 50e18
/// - denominator (decimal):  2e19
/// - result (decimal): 25e17
function divD8(D18 d1, D18 d2) pure returns (D18) {
    return D18.wrap(MathLib.mulDiv(D18.unwrap(d1), 1e18, D18.unwrap(d2)).toUint128());
}

/// @dev Multiplies one D18 with another one while retaining precision:
/// - value1 (decimal): 50e18
/// - value2 (decimal):  2e19
/// - result (decimal): 100e19
function mulD8(D18 d1, D18 d2) pure returns (D18) {
    return D18.wrap(MathLib.mulDiv(D18.unwrap(d1), D18.unwrap(d2), 1e18).toUint128());
}

/// @dev sugar for getting the inner representation of a D18
function inner(D18 d1) pure returns (uint128) {
    return D18.unwrap(d1);
}

/// @dev Multiplies a decimal by an integer. i.e:
/// - d (decimal):      1_500_000_000_000_000_000
/// - value (integer):  4_000_000_000_000_000_000
/// - result (integer): 6_000_000_000_000_000_000
function mulUint128(D18 d, uint128 value) pure returns (uint128) {
    return MathLib.mulDiv(D18.unwrap(d), value, 1e18).toUint128();
}

/// @dev Multiplies a decimal by an integer. i.e:
/// - d (decimal):      1_500_000_000_000_000_000
/// - value (integer):  4_000_000_000_000_000_000
/// - result (integer): 6_000_000_000_000_000_000
function mulUint256(D18 d, uint256 value) pure returns (uint256) {
    return MathLib.mulDiv(D18.unwrap(d), value, 1e18);
}

/// @dev  Divides an integer by a decimal, i.e.
/// @dev  Same as mulDiv for integers, i.e:
/// - d (decimal):      2_000_000_000_000_000_000
/// - value (integer):  100_000_000_000_000_000_000
/// - result (integer): 50_000_000_000_000_000_000
function reciprocalMulUint256(D18 d, uint256 value) pure returns (uint256) {
    return MathLib.mulDiv(value, 1e18, d.inner());
}

/// @dev Easy way to construct a decimal number
function d18(uint128 value) pure returns (D18) {
    return D18.wrap(value);
}

// TODO(@review): Discuss  mulInt128, mulInt256 vs. wrapping above code in library s.t. duplicate `mulInt` can co-exist
using {
    add as +, sub as -, divD8 as /, inner, mulD8 as *, mulUint128, mulUint256, reciprocalMulUint256
} for D18 global;
