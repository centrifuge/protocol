// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {VaultDetails} from "./ISpoke.sol";
import {IVault, VaultKind} from "./IVault.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {IVaultFactory} from "../factories/IVaultFactory.sol";
import {IRequestManager} from "../../interfaces/IRequestManager.sol";

interface IVaultRegistry {
    event File(bytes32 indexed what, address data);
    event DeployVault(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address indexed asset,
        uint256 tokenId,
        IVaultFactory factory,
        IVault vault,
        VaultKind kind
    );
    event LinkVault(
        PoolId indexed poolId, ShareClassId indexed scId, address indexed asset, uint256 tokenId, IVault vault
    );
    event UnlinkVault(
        PoolId indexed poolId, ShareClassId indexed scId, address indexed asset, uint256 tokenId, IVault vault
    );

    error MalformedVaultUpdateMessage();
    error UnknownVault();
    error InvalidRequestManager();
    error InvalidVault();
    error AlreadyLinkedVault();
    error AlreadyUnlinkedVault();
    error FileUnrecognizedParam();

    /// @notice Deploys a new vault
    ///
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id for which we want to deploy a vault
    /// @param factory The address of the corresponding vault factory
    /// @return address The address of the deployed vault
    function deployVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVaultFactory factory)
        external
        returns (IVault);

    /// @dev Used only for migrations
    function registerVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        IVaultFactory factory,
        IVault vault
    ) external;

    /// @notice Links a deployed vault to the given pool, share class and asset.
    ///
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id for which we want to deploy a vault
    /// @param vault The address of the deployed vault
    function linkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault) external;

    /// @notice Removes the link between a vault and the given pool, share class and asset.
    ///
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id for which we want to deploy a vault
    /// @param vault The address of the deployed vault
    function unlinkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault) external;

    /// @notice Function to get the details of a vault
    /// @dev    Reverts if vault does not exist
    ///
    /// @param vault The address of the vault to be checked for
    /// @return details The details of the vault including the underlying asset address, token id, asset id
    function vaultDetails(IVault vault) external view returns (VaultDetails memory details);

    /// @notice Checks whether a given vault is eligible for investing into a share class of a pool
    ///
    /// @param vault The address of the vault
    /// @return bool Whether vault is to a share class
    function isLinked(IVault vault) external view returns (bool);

    /// @notice Returns the address of the vault for a given pool, share class asset and requestManager
    /// @param manager the request manager associated to the vault, if 0, then it correspond to a full sync vault.
    function vault(PoolId poolId, ShareClassId scId, AssetId assetId, IRequestManager manager)
        external
        view
        returns (IVault vault);
}
