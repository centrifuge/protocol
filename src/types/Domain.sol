// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

type ShareClassId is uint32;

type AssetId is address;

type ItemId is uint32;

// Note: The less significate byte contains the kind of the account
type AccountId is uint32;

function kind(AccountId accountId) pure returns (uint8) {
    return uint8(AccountId.unwrap(accountId) & 0x000000FF);
}

using {kind} for AccountId global;
