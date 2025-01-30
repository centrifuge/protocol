// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {AssetId} from "src/types/AssetId.sol";
import {AssetIdLib} from "src/libraries/AssetIdLib.sol";
import {IAssetManager} from "src/interfaces/IAssetManager.sol";
import {ERC6909Fungible} from "src/ERC6909/ERC6909Fungible.sol";

contract AssetManager is ERC6909Fungible, IAssetManager {
    using AssetIdLib for address;

    mapping(AssetId => Asset) public asset;

    constructor(address owner) ERC6909Fungible(owner) {}

    /// @inheritdoc IAssetManager
    function decimals(address asset_) external view returns (uint8 decimals_) {
        decimals_ = asset[asset_.asAssetId()].decimals;
        require(decimals_ > 0, AssetNotFound());
    }

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

    function isRegistered(AssetId assetId) external view returns (bool) {
        return asset[assetId].decimals > 0;
    }
}
