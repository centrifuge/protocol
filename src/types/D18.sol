// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

// Small library to handle fixed point number operations with 18 decimals with static typing support.

import {MathLib} from "src/libraries/MathLib.sol";

type D18 is uint128;

using MathLib for uint256;

/// @notice Add operation (+).
function add(D18 d1, D18 d2) pure returns (D18) {
    return D18.wrap(D18.unwrap(d1) + D18.unwrap(d2));
}

/// @notice Substract operation (-).
function sub(D18 d1, D18 d2) pure returns (D18) {
    return D18.wrap(D18.unwrap(d1) - D18.unwrap(d2));
}

/// @notice Equal operation (==).
function eq(D18 d1, D18 d2) pure returns (bool) {
    return D18.unwrap(d1) == D18.unwrap(d2);
}

/// @notice Greater than operation (>).
function gt(D18 d1, D18 d2) pure returns (bool) {
    return D18.unwrap(d1) > D18.unwrap(d2);
}

/// @notice Greater than or equal operation (>=).
function gte(D18 d1, D18 d2) pure returns (bool) {
    return D18.unwrap(d1) >= D18.unwrap(d2);
}

/// @notice Lower than operation (<).
function lt(D18 d1, D18 d2) pure returns (bool) {
    return D18.unwrap(d1) < D18.unwrap(d2);
}

/// @notice Lower than or equal operaton (<=).
function lte(D18 d1, D18 d2) pure returns (bool) {
    return D18.unwrap(d1) <= D18.unwrap(d2);
}

/// @dev sugar for getting the inner representation of a D18.
function inner(D18 d) pure returns (uint128) {
    return D18.unwrap(d);
}

/// @notice Multiplies a decimal number (`D18`) by an integer (`uint128`).
/// @dev i.e:
/// - d (decimal):      1_500_000_000_000_000_000
/// - value (integer):  4_000_000_000_000_000_000
/// - result (integer): 6_000_000_000_000_000_000
function mulInt(D18 d, uint128 value) pure returns (uint128) {
    return MathLib.mulDiv(D18.unwrap(d), value, 1e18).toUint128();
}

/// @notice Easy way to construct a decimal number.
function d18(uint128 value) pure returns (D18) {
    return D18.wrap(value);
}

using {add as +, sub as -, eq as ==, gt as >, gte as >=, lt as <, lte as <=, inner, mulInt} for D18 global;
