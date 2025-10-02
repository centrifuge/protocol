// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AssetId} from "./AssetId.sol";

type AccountId is uint256;

function raw(AccountId accountId_) pure returns (uint256) {
    return AccountId.unwrap(accountId_);
}

function neq(AccountId a, AccountId b) pure returns (bool) {
    return AccountId.unwrap(a) != AccountId.unwrap(b);
}

function isNull(AccountId accountId) pure returns (bool) {
    return AccountId.unwrap(accountId) == 0;
}

function withCentrifugeId(uint16 centrifugeId, uint16 index) pure returns (AccountId) {
    return AccountId.wrap((uint256(centrifugeId) << 16) | uint256(index));
}

function withAssetId(AssetId assetId, uint16 index) pure returns (AccountId) {
    return AccountId.wrap((uint256(assetId.raw()) << 16) | uint256(index));
}

using {raw, neq as !=, isNull} for AccountId global;
