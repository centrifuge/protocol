// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {ItemId, AssetId, ShareClassId} from "src/types/Domain.sol";
import {IItemManager} from "src/interfaces/IItemManager.sol";

interface IHoldings is IItemManager {
    // TODO: add some events & errors here

    /// Returns the itemId for an specific asset in a share class
    function itemIdFromAsset(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (ItemId);

    /// Returns the share class and asset of a specific item
    function itemIdToAsset(PoolId poolId, ItemId itemId) external view returns (ShareClassId scId, AssetId assetId);
}
