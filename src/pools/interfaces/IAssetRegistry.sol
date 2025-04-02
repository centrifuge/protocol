// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC6909Fungible, IERC6909MetadataExt} from "src/misc/interfaces/IERC6909.sol";

import {AssetId} from "src/common/types/AssetId.sol";

/// @notice Interface for registering and handling assets
interface IAssetRegistry is IERC6909MetadataExt, IERC6909Fungible {
    event NewAssetEntry(AssetId indexed assetId, string name, string symbol, uint8 decimals);
    event ChainUpdate(uint16 indexed chainId, string name, string symbol);

    /// @dev Fired when id == 0
    error IncorrectAssetId();
    error AssetNotFound();

    struct Asset {
        string name;
        string symbol;
        uint8 decimals;
    }

    struct Chain {
        string name; // E.g. "Ethereum", "Base", "Arbitrum"
        string symbol; // E.g. "eth", "base", "arb"
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

    /// @notice             Method for updating metadata of chains
    function updateChain(uint16 chainId, string calldata name, string calldata symbol) external;
}
