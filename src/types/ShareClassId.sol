// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

type ShareClassId is bytes16;

function isNull(ShareClassId scId) pure returns (bool) {
    return ShareClassId.unwrap(scId) == 0;
}

function equals(ShareClassId left, ShareClassId right) pure returns (bool) {
    return ShareClassId.unwrap(left) == ShareClassId.unwrap(right);
}

function raw(ShareClassId scId) pure returns (bytes16) {
    return ShareClassId.unwrap(scId);
}

using {isNull, raw, equals as ==} for ShareClassId global;
