// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";

enum VaultKind {
    /// @dev Refers to AsyncVault
    Async,
    /// @dev not yet supported
    Sync,
    /// @dev Refers to SyncDepositVault
    SyncDepositAsyncRedeem
}

/// @title  IVaultManager Interface
/// @notice Interface for the vault manager contract, needed to link/unlink vaults correctly.
/// @dev Must be implemented by all vault managers
interface IVaultManager {
    /// @notice Adds new vault for `poolId`, `scId` and `asset`.
    function addVault(PoolId poolId, ShareClassId scId, IBaseVault vault, address asset, AssetId assetId) external;

    /// @notice Removes `vault` from `who`'s authorized callers
    function removeVault(PoolId poolId, ShareClassId scId, IBaseVault vault, address asset, AssetId assetId) external;

    /// @notice Returns the address of the vault for a given pool, share class and asset
    function vaultByAssetId(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (IBaseVault vault);

    /// @notice Checks whether the vault is partially (a)synchronous and if so returns the address of the secondary
    /// manager.
    ///
    /// @param vault The address of vault that is checked
    /// @return vaultKind_ The kind of the vault
    /// @return secondaryManager The address of the secondary manager if the vault is partially (a)synchronous, else
    /// points to zero address
    function vaultKind(IBaseVault vault) external view returns (VaultKind vaultKind_, address secondaryManager);
}
