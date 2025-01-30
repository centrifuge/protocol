// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Note: The less significate byte contains the kind of the account
type AccountId is uint32;

function kind(AccountId accountId_) pure returns (uint8) {
    return uint8(AccountId.unwrap(accountId_) & 0x000000FF);
}

function accountId(uint24 id, uint8 kind_) pure returns (AccountId) {
    return AccountId.wrap(id << 8 | kind_);
}

using {kind} for AccountId global;
