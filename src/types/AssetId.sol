// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

type AssetId is address;

function isNull(AssetId assetId) pure returns (bool) {
    return AssetId.unwrap(assetId) != address(0);
}

using {isNull} for AssetId global;
