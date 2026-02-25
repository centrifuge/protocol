// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";

interface IV3_0_1_AsyncRequestManager {
    function vault(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (address);
}

interface IV3_0_1_Spoke {
    function isLinked(address vault) external view returns (bool);
    function shareToken(PoolId poolId, ShareClassId scId) external view returns (address);
    function isPoolActive(PoolId poolId) external view returns (bool);
    function idToAsset(AssetId assetId) external view returns (address asset, uint256 decimals);
    function assetToId(address asset, uint256 tokenId) external view returns (AssetId assetId);
}

interface IV3_0_1_ShareToken {
    function vault(address asset) external view returns (address);
}
