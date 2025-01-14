// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

type ShareClassId is uint128;

function isNull(ShareClassId scId) pure returns (bool) {
    return ShareClassId.unwrap(scId) == 0;
}

using {isNull} for ShareClassId global;
