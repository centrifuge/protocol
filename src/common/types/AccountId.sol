// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

type AccountId is uint32;

function raw(AccountId accountId_) pure returns (uint32) {
    return AccountId.unwrap(accountId_);
}

function increment(AccountId accountId_) pure returns (AccountId) {
    return AccountId.wrap(AccountId.unwrap(accountId_) + 1);
}

using {raw, increment} for AccountId global;
