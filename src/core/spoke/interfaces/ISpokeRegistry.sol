// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IShareToken} from "./IShareToken.sol";
import {IVault, VaultKind} from "./IVault.sol";

import {D18} from "../../../misc/types/D18.sol";

import {Price} from "../types/Price.sol";
import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {IRequestManager} from "../../interfaces/IRequestManager.sol";
import {IVaultFactory} from "../factories/interfaces/IVaultFactory.sol";

/// @dev Centrifuge pools
struct Pool {
    /// @dev Timestamp of pool creation
    uint64 createdAt;
}

/// @dev Each Centrifuge pool is associated to 1 or more share classes
struct ShareClassDetails {
    IShareToken shareToken;
    /// @dev Each share class has an individual price per share class unit in pool denomination (POOL_UNIT/SHARE_UNIT)
    Price pricePoolPerShare;
}

struct AssetIdKey {
    /// @dev The address of the asset
    address asset;
    /// @dev The ERC6909 token id or 0, if the underlying asset is an ERC20
    uint256 tokenId;
}

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

interface ISpokeRegistry {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event File(bytes32 indexed what, address data);
    event AddPool(PoolId indexed poolId);
    event AddShareClass(PoolId indexed poolId, ShareClassId indexed scId, IShareToken token);
    event SetRequestManager(PoolId indexed poolId, IRequestManager manager);
    event UpdateManager(PoolId indexed poolId, address indexed who, bool canManage);
    event UpdateBridger(PoolId indexed poolId, address indexed who, bool canBridge);
    event UpdateAssetPrice(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address indexed asset,
        uint256 tokenId,
        D18 price,
        uint64 computedAt
    );
    event UpdateSharePrice(PoolId indexed poolId, ShareClassId indexed scId, D18 price, uint64 computedAt);
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

    error FileUnrecognizedParam();
    error PoolAlreadyAdded();
    error InvalidPool();
    error ShareClassAlreadyRegistered();
    error CannotSetOlderPrice();
    error UnknownAsset();
    error ShareTokenDoesNotExist();
    error InvalidPrice();
    error InvalidRequestManager();
    error UnknownVault();
    error InvalidVault();
    error AlreadyLinkedVault();
    error AlreadyUnlinkedVault();

    //----------------------------------------------------------------------------------------------
    // Setter methods
    //----------------------------------------------------------------------------------------------

    /// @notice Adds a new pool to the registry
    /// @param poolId The pool identifier
    function addPool(PoolId poolId) external;

    /// @notice Adds a share class to the registry
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param shareToken_ The share token contract
    function addShareClass(PoolId poolId, ShareClassId scId, IShareToken shareToken_) external;

    /// @notice Links a share token to a pool and share class
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param shareToken_ The share token contract
    function linkToken(PoolId poolId, ShareClassId scId, IShareToken shareToken_) external;

    /// @notice Sets the request manager for a pool
    /// @param poolId The pool identifier
    /// @param manager The request manager contract
    function setRequestManager(PoolId poolId, IRequestManager manager) external;

    /// @notice Grants or revokes the pool manager role for an address
    /// @param poolId The pool identifier
    /// @param who The address whose role is updated
    /// @param canManage Whether the address is a manager
    function updateManager(PoolId poolId, address who, bool canManage) external;

    /// @notice Grants or revokes the bridger role for an address, gating cross-chain share transfers
    /// @param poolId The pool identifier
    /// @param who The address whose role is updated
    /// @param canBridge Whether the address is a bridger
    function updateBridger(PoolId poolId, address who, bool canBridge) external;

    //----------------------------------------------------------------------------------------------
    // Vault management
    //----------------------------------------------------------------------------------------------

    /// @notice Register a vault (used for vault deployments and migrations)
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
    function linkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault) external;

    /// @notice Removes the link between a vault and the given pool, share class and asset
    function unlinkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault) external;

    /// @notice Creates a new asset ID and registers the asset mapping in the registry
    /// @param centrifugeId The centrifuge chain ID
    /// @param asset The asset address
    /// @param tokenId The ERC6909 token id or 0 for ERC20
    /// @return assetId The new asset ID
    function createAssetId(uint16 centrifugeId, address asset, uint256 tokenId) external returns (AssetId assetId);

    /// @notice Updates the price per share for a given pool and share class
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param price The price of pool currency per share class token
    /// @param computedAt The timestamp when the price was computed
    function updatePricePoolPerShare(PoolId poolId, ShareClassId scId, D18 price, uint64 computedAt) external;

    /// @notice Updates the price per asset for a given pool, share class and asset
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id
    /// @param price The price of pool currency per asset unit
    /// @param computedAt The timestamp when the price was computed
    function updatePricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, D18 price, uint64 computedAt)
        external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns whether the given pool id is active
    /// @param poolId The pool id
    /// @return Whether the pool is active
    function isPoolActive(PoolId poolId) external view returns (bool);

    /// @notice Returns the share class token for a given pool and share class id
    /// @dev Reverts if share class does not exist
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @return The address of the share token
    function shareToken(PoolId poolId, ShareClassId scId) external view returns (IShareToken);

    /// @notice Returns the asset address and tokenId associated with a given asset id.
    /// @dev Reverts if asset id does not exist
    /// @param assetId The underlying internal uint128 assetId.
    /// @return asset The address of the asset linked to the given asset id.
    /// @return tokenId The token id corresponding to the asset, i.e. zero if ERC20 or non-zero if ERC6909.
    function idToAsset(AssetId assetId) external view returns (address asset, uint256 tokenId);

    /// @notice Returns the asset address and tokenId for a given asset id, or zero values if not registered.
    /// @dev Non-reverting variant of `idToAsset`, so callers can probe registration without a try/catch.
    /// @param assetId The underlying internal uint128 assetId.
    /// @return asset The address of the asset, or the zero address if the asset id is not registered.
    /// @return tokenId The token id corresponding to the asset, i.e. zero if ERC20 or non-zero if ERC6909.
    function idToAssetOrNull(AssetId assetId) external view returns (address asset, uint256 tokenId);

    /// @notice Returns assetId given the asset address and tokenId.
    /// @dev Reverts if asset id does not exist
    /// @param asset The address of the asset linked to the given asset id.
    /// @param tokenId The token id corresponding to the asset, i.e. zero if ERC20 or non-zero if ERC6909.
    /// @return assetId The underlying internal uint128 assetId.
    function assetToId(address asset, uint256 tokenId) external view returns (AssetId assetId);

    /// @notice Returns the asset id for a given asset, or the null asset id if it is not registered.
    /// @dev Non-reverting variant of `assetToId`, so callers can probe registration without a try/catch.
    /// @param asset The address of the asset linked to the given asset id.
    /// @param tokenId The token id corresponding to the asset, i.e. zero if ERC20 or non-zero if ERC6909.
    /// @return assetId The underlying internal uint128 assetId, or null if the asset is not registered.
    function assetToIdOrNull(address asset, uint256 tokenId) external view returns (AssetId assetId);

    /// @notice Returns the price per share for a given pool and share class
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param checkValidity Whether to check if the price is valid
    /// @return price The pool price per share
    function pricePoolPerShare(PoolId poolId, ShareClassId scId, bool checkValidity) external view returns (D18 price);

    /// @notice Returns the price per asset for a given pool, share class and asset
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id
    /// @param checkValidity Whether to check if the price is valid
    /// @return price The pool price per asset unit
    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        external
        view
        returns (D18 price);

    /// @notice Returns the timestamp at which the share price was last computed (0 if never)
    /// @param poolId The pool id
    /// @param scId The share class id
    function pricePoolPerShareComputedAt(PoolId poolId, ShareClassId scId) external view returns (uint64 computedAt);

    /// @notice Returns the timestamp at which the asset price was last computed (0 if never)
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id
    function pricePoolPerAssetComputedAt(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint64 computedAt);

    /// @notice Returns the request manager for a given pool
    /// @param poolId The pool id
    /// @return manager The request manager for the pool
    function requestManager(PoolId poolId) external view returns (IRequestManager manager);

    /// @notice Returns whether an address holds the pool manager role
    function manager(PoolId poolId, address who) external view returns (bool);

    /// @notice Returns whether an address holds the bridger role for a pool
    function bridger(PoolId poolId, address who) external view returns (bool);

    /// @notice Returns the details of a vault
    /// @dev Reverts if vault does not exist
    function vaultDetails(IVault vault) external view returns (VaultDetails memory details);

    /// @notice Checks whether a given vault is linked to a share class
    function isLinked(IVault vault) external view returns (bool);

    /// @notice Returns the address of the vault for a given pool, share class, asset and request manager
    function vault(PoolId poolId, ShareClassId scId, AssetId assetId, IRequestManager manager)
        external
        view
        returns (IVault vaultAddress);
}
