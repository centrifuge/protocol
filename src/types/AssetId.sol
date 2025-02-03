// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MathLib} from "src/libraries/MathLib.sol";

// @dev Composite Id of the chainId (uint32) where the asset resides
//      and a local counter (uint32) that is part of the contract that registers the asset.
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

function addrToAssedId(address asset) pure returns (AssetId) {
    return AssetId.wrap(MathLib.toUint128(uint256(uint160(asset))));
}

using {isNull, addr, raw} for AssetId global;
