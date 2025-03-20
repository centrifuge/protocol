// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @dev Composite Id of the chainId (uint32) where the asset resides
///      and a local counter (uint32) that is part of the contract that registers the asset.
type AssetId is uint128;

function isNull(AssetId assetId) pure returns (bool) {
    return AssetId.unwrap(assetId) == 0;
}

function addr(AssetId assetId) pure returns (address) {
    return address(uint160(AssetId.unwrap(assetId)));
}

function raw(AssetId assetId) pure returns (uint128) {
    return AssetId.unwrap(assetId);
}

function chainId(AssetId assetId) pure returns (uint32) {
    return uint16(AssetId.unwrap(assetId) >> 112);
}

function newAssetId(uint16 centrifugeChainId, uint32 counter) pure returns (AssetId) {
    return AssetId.wrap((uint128(centrifugeChainId) << 112) + counter);
}

function newAssetId(uint32 isoCode) pure returns (AssetId) {
    return AssetId.wrap(isoCode);
}

using {isNull, addr, raw, chainId} for AssetId global;
