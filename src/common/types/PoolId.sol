// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MathLib} from "../../misc/libraries/MathLib.sol";

using MathLib for uint256;

type PoolId is uint64;

function centrifugeId(PoolId poolId) pure returns (uint16) {
    return uint16(PoolId.unwrap(poolId) >> 48);
}

function newPoolId(uint16 centrifugeId_, uint48 localPoolId) pure returns (PoolId) {
    return PoolId.wrap((uint64(centrifugeId_) << 48) | uint64(localPoolId));
}

function isNull(PoolId poolId) pure returns (bool) {
    return PoolId.unwrap(poolId) == 0;
}

function isEqual(PoolId a, PoolId b) pure returns (bool) {
    return PoolId.unwrap(a) == PoolId.unwrap(b);
}

function raw(PoolId poolId) pure returns (uint64) {
    return PoolId.unwrap(poolId);
}

using {centrifugeId, isNull, raw, isEqual as ==} for PoolId global;
