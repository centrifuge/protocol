// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AssetId} from "src/types/AssetId.sol";

import {IERC6909Fungible} from "src/interfaces/ERC6909/IERC6909Fungible.sol";
import {IERC6909MetadataExt} from "src/interfaces/ERC6909/IERC6909MetadataExt.sol";

/// @notice Interface for register and handling assets
interface IAssetManager is IERC6909MetadataExt, IERC6909Fungible {
    event NewAssetEntry(AssetId indexed assetId, string name, string symbol, uint8 decimals);

    /// @dev Fired when id == 0
    error IncorrectAssetId();
    error AssetNotFound();

    struct Asset {
        string name;
        string symbol;
        uint8 decimals;
    }

    /// @notice             A getter function to get an Asset based on AssetId
    function asset(AssetId assetId) external view returns (string memory name, string memory symbol, uint8 decimals);

    /// @notice             Checks whether an asset is registered or not
    function isRegistered(AssetId assetId) external view returns (bool);

    /// @notice             Method responsible for registering assets that can be used for investing and holdings
    /// @dev                This is expected to be called by PoolManager only.
    ///                     Adding new assets happens from the Vault's side.
    ///                     `decimals` MUST be different than 0.
    function registerAsset(AssetId assetId, string calldata name, string calldata symbol, uint8 decimals) external;
}
