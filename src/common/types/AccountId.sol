// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

type AccountId is uint32;

function raw(AccountId accountId_) pure returns (uint32) {
    return AccountId.unwrap(accountId_);
}

function increment(AccountId accountId_) pure returns (AccountId) {
    return AccountId.wrap(AccountId.unwrap(accountId_) + 1);
}

function neq(AccountId a, AccountId b) pure returns (bool) {
    return AccountId.unwrap(a) != AccountId.unwrap(b);
}

using {raw, increment, neq as !=} for AccountId global;
