// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {ItemId, AssetId, ShareClassId} from "src/types/Domain.sol";
import {IItemManager} from "src/interfaces/IItemManager.sol";

interface IHoldings is IItemManager {
    // TODO: add some events & errors here

    function itemIdFromAsset(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (ItemId);
}
