// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {IVault} from "src/spoke/interfaces/IVault.sol";

interface IVaultManager {
    /// @notice Emitted when a new vault is added
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param assetId The asset ID
    /// @param vault The address of the vault being added
    event AddVault(PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, IVault vault);

    /// @notice Emitted when a vault is removed
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param assetId The asset ID
    /// @param vault The address of the vault being removed
    event RemoveVault(PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, IVault vault);

    /// @notice Adds new vault for `poolId`, `scId` and `assetId`.
    function addVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault, address asset, uint256 tokenId)
        external;

    /// @notice Removes `vault` from `who`'s authorized callers
    function removeVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IVault vault,
        address asset,
        uint256 tokenId
    ) external;

    /// @notice Returns the address of the vault for a given pool, share class and asset
    function vaultByAssetId(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (IVault vault);
}
