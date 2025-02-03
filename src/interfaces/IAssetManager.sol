// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AssetId} from "src/types/AssetId.sol";
import {IERC6909MetadataExt} from "src/interfaces/ERC6909/IERC6909MetadataExt.sol";

// TODO
interface IAssetManager is IERC6909MetadataExt {
    event NewAssetEntry(AssetId indexed assetId, bytes name, bytes32 symbol, uint8 decimals);

    /// @dev Fired when id == 0
    error IncorrectAssetId();
    error AssetNotFound();

    struct Asset {
        bytes name;
        bytes32 symbol;
        uint8 decimals;
    }

    /// @notice             A getter function to get an Asset based on AssetId
    function asset(AssetId assetId) external view returns (bytes memory name, bytes32 symbol, uint8 decimals);

    /// @notice             Checks whether an asset is registered or nto
    function isRegistered(AssetId assetId) external view returns (bool);

    /// @notice             Method responsible for registering assets that can be used for investing and holdings
    /// @dev                This is expected to be called by PoolManager only.
    ///                     Adding new assets happens from the Vault's side.
    ///                     `decimals` MUST be different than 0.
    function registerAsset(AssetId assetId, bytes calldata name, bytes32 symbol, uint8 decimals) external;
}
