// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MathLib} from "src/misc/libraries/MathLib.sol";

using MathLib for uint256;

type PoolId is uint64;

function chainId(PoolId poolId) pure returns (uint16) {
    return uint16(PoolId.unwrap(poolId) >> 48);
}

function newPoolId(uint16 centrifugeChainId, uint48 localPoolId) pure returns (PoolId) {
    return PoolId.wrap((uint64(centrifugeChainId) << 48) | uint64(localPoolId));
}

function isNull(PoolId poolId) pure returns (bool) {
    return PoolId.unwrap(poolId) == 0;
}

function raw(PoolId poolId) pure returns (uint64) {
    return PoolId.unwrap(poolId);
}

using {chainId, isNull, raw} for PoolId global;
