// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

type AssetId is uint64;

function isNull(AssetId assetId) pure returns (bool) {
    return AssetId.unwrap(assetId) == 0;
}

function addr(AssetId assetId) pure returns (address) {
    return address(uint160(AssetId.unwrap(assetId)));
}

function raw(AssetId assetId) pure returns (uint64) {
    return AssetId.unwrap(assetId);
}

using {isNull, addr, raw} for AssetId global;
