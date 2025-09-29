// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "./PoolId.sol";

type ShareClassId is bytes16;

function isNull(ShareClassId scId) pure returns (bool) {
    return ShareClassId.unwrap(scId) == 0;
}

function index(ShareClassId scId) pure returns (uint32) {
    return uint32(uint128(ShareClassId.unwrap(scId)));
}

function equals(ShareClassId left, ShareClassId right) pure returns (bool) {
    return ShareClassId.unwrap(left) == ShareClassId.unwrap(right);
}

function raw(ShareClassId scId) pure returns (bytes16) {
    return ShareClassId.unwrap(scId);
}

function newShareClassId(PoolId poolId, uint32 index_) pure returns (ShareClassId scId) {
    return ShareClassId.wrap(bytes16((uint128(PoolId.unwrap(poolId)) << 64) + index_));
}

using {isNull, index, raw, equals as ==} for ShareClassId global;
