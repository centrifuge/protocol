// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {AssetId} from "src/types/AssetId.sol";
import {IAssetManager} from "src/interfaces/IAssetManager.sol";
import {ERC6909Fungible} from "src/ERC6909/ERC6909Fungible.sol";
import {IERC6909MetadataExt} from "src/interfaces/ERC6909/IERC6909MetadataExt.sol";

contract AssetManager is ERC6909Fungible, IAssetManager {
    using MathLib for uint256;

    mapping(AssetId => Asset) public asset;

    constructor(address owner) ERC6909Fungible(owner) {}

    /// @inheritdoc IAssetManager
    function registerAsset(AssetId assetId_, string calldata name_, string calldata symbol_, uint8 decimals_)
        external
        auth
    {
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

    /// @inheritdoc IERC6909MetadataExt
    function decimals(uint256 asset_) external view returns (uint8 decimals_) {
        decimals_ = asset[AssetId.wrap(asset_.toUint128())].decimals;
        require(decimals_ > 0, AssetNotFound());
    }

    /// @inheritdoc IERC6909MetadataExt
    function name(uint256 asset_) external view returns (string memory) {
        return asset[AssetId.wrap(asset_.toUint128())].name;
    }

    /// @inheritdoc IERC6909MetadataExt
    function symbol(uint256 asset_) external view returns (string memory) {
        return asset[AssetId.wrap(asset_.toUint128())].symbol;
    }

    function supportsInterface(bytes4 interfaceId) public pure virtual override(ERC6909Fungible) returns (bool) {
        return type(IERC6909MetadataExt).interfaceId == interfaceId || super.supportsInterface(interfaceId);
    }
}
