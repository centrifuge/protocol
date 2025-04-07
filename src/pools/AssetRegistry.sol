// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {ERC6909Fungible} from "src/misc/ERC6909Fungible.sol";
import {IERC6909MetadataExt} from "src/misc/interfaces/IERC6909.sol";

import {AssetId} from "src/common/types/AssetId.sol";
import {IAssetRegistry} from "src/pools/interfaces/IAssetRegistry.sol";

contract AssetRegistry is ERC6909Fungible, IAssetRegistry {
    using MathLib for uint256;

    mapping(AssetId => Asset) public asset;
    mapping(uint16 chainId => Chain) public chain;

    constructor(address owner) ERC6909Fungible(owner) {}

    /// @inheritdoc IAssetRegistry
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

    /// @inheritdoc IAssetRegistry
    function setChain(uint16 chainId, string calldata name_, string calldata symbol_) external auth {
        Chain storage chain_ = chain[chainId];
        chain_.name = name_;
        chain_.symbol = symbol_;

        emit UpdateChain(chainId, name_, symbol_);
    }

    /// @inheritdoc IERC6909MetadataExt
    function name(uint256 asset_) external view returns (string memory) {
        AssetId assetId = AssetId.wrap(asset_.toUint128());
        Chain memory chain_ = chain[assetId.chainId()];

        if (bytes(chain_.name).length == 0) return asset[assetId].name;
        return string.concat(chain_.name, " ", asset[assetId].name);
    }

    /// @inheritdoc IERC6909MetadataExt
    function symbol(uint256 asset_) external view returns (string memory) {
        AssetId assetId = AssetId.wrap(asset_.toUint128());
        Chain memory chain_ = chain[assetId.chainId()];

        return string.concat(chain_.symbol, asset[assetId].symbol);
    }

    /// @inheritdoc IAssetRegistry
    function unitAmount(AssetId assetId) external view returns (uint128) {
        return (10 ** this.decimals(assetId)).toUint128();
    }

    /// @inheritdoc IAssetRegistry
    function decimals(AssetId assetId) external view returns (uint8 decimals_) {
        decimals_ = asset[assetId].decimals;
        require(decimals_ > 0, AssetNotFound());
    }

    /// @inheritdoc IERC6909MetadataExt
    function decimals(uint256 asset_) external view returns (uint8 decimals_) {
        decimals_ = asset[AssetId.wrap(asset_.toUint128())].decimals;
        require(decimals_ > 0, AssetNotFound());
    }

    /// @inheritdoc IAssetRegistry
    function isRegistered(AssetId assetId) external view returns (bool) {
        return asset[assetId].decimals > 0;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        pure
        virtual
        override(ERC6909Fungible, IERC165)
        returns (bool)
    {
        return type(IERC6909MetadataExt).interfaceId == interfaceId || super.supportsInterface(interfaceId);
    }
}
