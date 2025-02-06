// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MathLib} from "src/libraries/MathLib.sol";

using MathLib for uint256;

type PoolId is uint64;

function chainId(PoolId poolId) pure returns (uint32) {
    return uint32(PoolId.unwrap(poolId) >> 32);
}

function newPoolId(uint32 localPoolId) view returns (PoolId) {
    return PoolId.wrap((uint64(block.chainid.toUint32()) << 32) | uint64(localPoolId));
}

function isNull(PoolId assetId) pure returns (bool) {
    return PoolId.unwrap(assetId) == 0;
}

function raw(PoolId assetId) pure returns (uint64) {
    return PoolId.unwrap(assetId);
}

using {chainId, isNull, raw} for PoolId global;
