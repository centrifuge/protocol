// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Note: The less significate byte contains the kind of the account
type AccountId is uint32;

function kind(AccountId accountId_) pure returns (uint8) {
    return uint8(AccountId.unwrap(accountId_) & 0x000000FF);
}

function newAccountId(uint24 id, uint8 kind_) pure returns (AccountId) {
    return AccountId.wrap((uint32(id) << 8) | kind_);
}

function raw(AccountId accountId_) pure returns (uint32) {
    return AccountId.unwrap(accountId_);
}

using {kind, raw} for AccountId global;
