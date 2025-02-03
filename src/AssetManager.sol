// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {AssetId, addrToAssetId} from "src/types/AssetId.sol";
import {IAssetManager} from "src/interfaces/IAssetManager.sol";
import {ERC6909Fungible} from "src/ERC6909/ERC6909Fungible.sol";
import {IERC6909MetadataExt} from "src/interfaces/ERC6909/IERC6909MetadataExt.sol";

contract AssetManager is ERC6909Fungible, IAssetManager {
    mapping(AssetId => Asset) public asset;

    constructor(address owner) ERC6909Fungible(owner) {}

    /// @inheritdoc IERC6909MetadataExt
    function decimals(address asset_) external view returns (uint8 decimals_) {
        decimals_ = asset[addrToAssetId(asset_)].decimals;
        require(decimals_ > 0, AssetNotFound());
    }

    /// @inheritdoc IERC6909MetadataExt
    function name(address asset_) external view returns (bytes memory) {
        return asset[addrToAssetId(asset_)].name;
    }

    /// @inheritdoc IERC6909MetadataExt
    function symbol(address asset_) external view returns (bytes32) {
        return asset[addrToAssetId(asset_)].symbol;
    }

    /// @inheritdoc IAssetManager
    function registerAsset(AssetId assetId_, bytes calldata name_, bytes32 symbol_, uint8 decimals_) external auth {
        require(!assetId_.isNull(), IncorrectAssetId());
        Asset storage asset_ = asset[assetId_];
        asset_.name = name_;
        asset_.symbol = symbol_;

        if (asset_.decimals == 0) {
            asset_.decimals = decimals_;
        }

        emit NewAssetEntry(assetId_, name_, symbol_, asset_.decimals);
    }

    /// @inheritdoc IAssetManager

    function isRegistered(AssetId assetId) external view returns (bool) {
        return asset[assetId].decimals > 0;
    }
}
