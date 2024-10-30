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

/// @dev sugar for getting the inner representation of a D18
function inner(D18 d1) pure returns (uint128) {
    return D18.unwrap(d1);
}

/// @dev Multiplies a decimal by an integer. i.e:
/// - d (decimal):      1_500_000_000_000_000_000
/// - value (integer):  4_000_000_000_000_000_000
/// - result (integer): 6_000_000_000_000_000_000
function mulInt(D18 d, uint128 value) pure returns (uint128) {
    return MathLib.mulDiv(D18.unwrap(d), value, 1e18).toUint128();
}

/// @dev  Divides an integer by a decimal, i.e.
/// @dev  Same as mulDiv for integers, i.e:
/// - d (decimal):      2_000_000_000_000_000_000
/// - value (integer):  100_000_000_000_000_000_000
/// - result (integer): 50_000_000_000_000_000_000
function reciprocalMulInt(D18 d, uint128 value) pure returns (uint128) {
    return MathLib.mulDiv(value, 1e18, d.inner()).toUint128();
}

/// @dev Easy way to construct a decimal number
function d18(uint128 value) pure returns (D18) {
    return D18.wrap(value);
}

using {add as +, sub as -, inner, mulInt, reciprocalMulInt} for D18 global;
