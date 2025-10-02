// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../types/PoolId.sol";
import {AssetId} from "../../../types/AssetId.sol";
import {ShareClassId} from "../../../types/ShareClassId.sol";
import {IRequestManager} from "../../../interfaces/IRequestManager.sol";

import {IVault} from "../IVault.sol";

IRequestManager constant REQUEST_MANAGER_V3_0 = IRequestManager(0xf06f89A1b6C601235729A689595571B7455Dd433);

interface IVaultManager {
    error VaultAlreadyExists();
    error VaultDoesNotExist();

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
