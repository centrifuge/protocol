// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

type AccountId is uint32;

function raw(AccountId accountId_) pure returns (uint32) {
    return AccountId.unwrap(accountId_);
}

function neq(AccountId a, AccountId b) pure returns (bool) {
    return AccountId.unwrap(a) != AccountId.unwrap(b);
}

function isNull(AccountId accountId) pure returns (bool) {
    return AccountId.unwrap(accountId) == 0;
}

function withCentrifugeId(uint16 centrifugeId, uint16 index) pure returns (AccountId) {
    return AccountId.wrap((uint32(centrifugeId) << 16) | uint32(index));
}

using {raw, neq as !=, isNull} for AccountId global;
