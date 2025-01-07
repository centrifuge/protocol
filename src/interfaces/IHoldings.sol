// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ItemId} from "src/types/Domain.sol";
import {PoolId} from "src/types/PoolId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {IItemManager} from "src/interfaces/IItemManager.sol";

interface IHoldings is IItemManager {
    /// @notice Valuation is not valid.
    error WrongValuation();

    /// @notice AssetId is not valid.
    error WrongAssetId();

    /// @notice ShareClassId is not valid.
    error WrongShareClassId();

    /// @notice Returns the itemId for an specific asset in a share class
    function itemIdFromAsset(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (ItemId);

    /// @notice Returns the share class and asset of a specific item
    function itemIdToAsset(PoolId poolId, ItemId itemId) external view returns (ShareClassId scId, AssetId assetId);
}
