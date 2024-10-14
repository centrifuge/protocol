// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {MathLib} from "src/libraries/MathLib.sol";

type Decimal18 is uint128;

function add(Decimal18 d1, Decimal18 d2) pure returns (Decimal18) {
    return Decimal18.wrap(Decimal18.unwrap(d1) + Decimal18.unwrap(d2));
}

function sub(Decimal18 d1, Decimal18 d2) pure returns (Decimal18) {
    return Decimal18.wrap(Decimal18.unwrap(d1) - Decimal18.unwrap(d2));
}

function inner(Decimal18 d1) pure returns (uint128) {
    return Decimal18.unwrap(d1);
}

/// Multiplies a decimal by an integer
/// (dev) i.e:
/// - d (decimal):      1_500_000_000_000_000_000
/// - value (integer):  4_000_000_000_000_000_000
/// - result (integer): 6_000_000_000_000_000_000
function mulInt(Decimal18 d, uint128 value) pure returns (uint128) {
    return MathLib.toUint128(MathLib.mulDiv(Decimal18.unwrap(d), value, 1e18));
}

/// Easy way to construct a decimal number
function d18(uint128 value) pure returns (Decimal18) {
    return Decimal18.wrap(value);
}

using {add as +, sub as -, inner, mulInt} for Decimal18 global;
