// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IVault, VaultKind} from "./IVault.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {IRequestManager} from "../../interfaces/IRequestManager.sol";
import {IVaultFactory} from "../factories/interfaces/IVaultFactory.sol";

struct VaultDetails {
    /// @dev AssetId of the asset
    AssetId assetId;
    /// @dev Address of the asset
    address asset;
    /// @dev TokenId of the asset - zero if asset is ERC20, non-zero if asset is ERC6909
    uint256 tokenId;
    /// @dev Whether the vault is linked to a share class atm
    bool isLinked;
}

interface IVaultRegistry {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

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

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error MalformedVaultUpdateMessage();
    error UnknownVault();
    error InvalidRequestManager();
    error InvalidVault();
    error AlreadyLinkedVault();
    error AlreadyUnlinkedVault();
    error FileUnrecognizedParam();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'spoke'
    function file(bytes32 what, address data) external;

    //----------------------------------------------------------------------------------------------
    // Vault management
    //----------------------------------------------------------------------------------------------

    /// @notice Deploys a new vault
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id for which we want to deploy a vault
    /// @param factory The address of the corresponding vault factory
    /// @return The address of the deployed vault
    function deployVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVaultFactory factory)
        external
        returns (IVault);

    /// @notice Register a vault (used only for migrations)
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id
    /// @param asset The asset address
    /// @param tokenId The token id (0 for ERC20)
    /// @param factory The vault factory address
    /// @param vault The vault address
    function registerVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        IVaultFactory factory,
        IVault vault
    ) external;

    /// @notice Links a deployed vault to the given pool, share class and asset
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id for which we want to deploy a vault
    /// @param vault The address of the deployed vault
    function linkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault) external;

    /// @notice Removes the link between a vault and the given pool, share class and asset
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id for which we want to deploy a vault
    /// @param vault The address of the deployed vault
    function unlinkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault) external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Function to get the details of a vault
    /// @dev Reverts if vault does not exist
    /// @param vault The address of the vault to be checked for
    /// @return details The details of the vault including the underlying asset address, token id, asset id
    function vaultDetails(IVault vault) external view returns (VaultDetails memory details);

    /// @notice Checks whether a given vault is eligible for investing into a share class of a pool
    /// @param vault The address of the vault
    /// @return Whether vault is linked to a share class
    function isLinked(IVault vault) external view returns (bool);

    /// @notice Returns the address of the vault for a given pool, share class asset and requestManager
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id
    /// @param manager The request manager associated to the vault, if 0, then it correspond to a full sync vault
    /// @return vault The vault address
    function vault(PoolId poolId, ShareClassId scId, AssetId assetId, IRequestManager manager)
        external
        view
        returns (IVault vault);
}
