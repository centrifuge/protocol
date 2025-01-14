// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ItemId} from "src/types/ItemId.sol";
import {PoolId} from "src/types/PoolId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {AccountId} from "src/types/AccountId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {IItemManager} from "src/interfaces/IItemManager.sol";
import {IERC7726} from "src/interfaces/IERC7726.sol";

interface IHoldings is IItemManager {
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 indexed what, address addr);

    /// @notice Emitted when a call to `file()` was performed.
    event AllowedAsset(PoolId indexed poolId, AssetId indexed assetId, bool isAllow);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedWhat();

    /// @notice AssetId is not valid.
    error WrongAssetId();

    /// @notice ShareClassId is not valid.
    error WrongShareClassId();

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'poolRegistry' string value.
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;

    /// @notice Allows an asset to be used as a holding
    function allowAsset(PoolId poolId, AssetId assetId, bool isAllow) external;

    /// @notice returns the allowance of an asset as a holding
    function isAssetAllowed(PoolId poolId, AssetId assetId) external returns (bool);

    /// @notice Returns the itemId for an specific asset in a share class
    function itemId(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (ItemId);

    /// @notice Returns the share class and asset of a specific item
    function itemProperties(PoolId poolId, ItemId itemId) external view returns (ShareClassId scId, AssetId assetId);
}
