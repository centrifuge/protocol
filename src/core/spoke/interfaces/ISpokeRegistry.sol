// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IShareToken} from "./IShareToken.sol";

import {D18} from "../../../misc/types/D18.sol";

import {Price} from "../types/Price.sol";
import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {IRequestManager} from "../../interfaces/IRequestManager.sol";

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

/// @dev Eech share token maps to a pool and share class
struct TokenDetails {
    PoolId poolId;
    ShareClassId scId;
}

struct AssetIdKey {
    /// @dev The address of the asset
    address asset;
    /// @dev The ERC6909 token id or 0, if the underlying asset is an ERC20
    uint256 tokenId;
}

interface ISpokeRegistry {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event File(bytes32 indexed what, address data);
    event AddPool(PoolId indexed poolId);
    event AddShareClass(PoolId indexed poolId, ShareClassId indexed scId, IShareToken token);
    event SetRequestManager(PoolId indexed poolId, IRequestManager manager);
    event UpdateAssetPrice(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address indexed asset,
        uint256 tokenId,
        D18 price,
        uint64 computedAt
    );
    event UpdateSharePrice(PoolId indexed poolId, ShareClassId indexed scId, D18 price, uint64 computedAt);
    event UpdateMaxSharePriceAge(PoolId indexed poolId, ShareClassId indexed scId, uint64 maxPriceAge);
    event UpdateMaxAssetPriceAge(
        PoolId indexed poolId, ShareClassId indexed scId, address indexed asset, uint256 tokenId, uint64 maxPriceAge
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

    /// @notice Updates a share token's vault reference for a specific asset
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param asset The asset address
    /// @param vault The vault address to set (or address(0) to unset)
    function setShareTokenVault(PoolId poolId, ShareClassId scId, address asset, address vault) external;

    /// @notice Sets the request manager for a pool
    /// @param poolId The pool identifier
    /// @param manager The request manager contract
    function setRequestManager(PoolId poolId, IRequestManager manager) external;

    /// @notice Registers an asset mapping in the registry
    /// @param assetId The asset identifier
    /// @param asset The asset address
    /// @param tokenId The ERC6909 token id or 0 for ERC20
    function registerAsset(AssetId assetId, address asset, uint256 tokenId) external;

    /// @notice Generates a new asset ID
    /// @param centrifugeId The centrifuge chain ID
    /// @return assetId The new asset ID
    function generateAssetId(uint16 centrifugeId) external returns (AssetId assetId);

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

    /// @notice Sets the maximum age for a share price
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param maxPriceAge The maximum age in seconds
    function setMaxSharePriceAge(PoolId poolId, ShareClassId scId, uint64 maxPriceAge) external;

    /// @notice Sets the maximum age for an asset price
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id
    /// @param maxPriceAge The maximum age in seconds
    function setMaxAssetPriceAge(PoolId poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge) external;

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

    /// @notice Returns assetId given the asset address and tokenId.
    /// @dev Reverts if asset id does not exist
    /// @param asset The address of the asset linked to the given asset id.
    /// @param tokenId The token id corresponding to the asset, i.e. zero if ERC20 or non-zero if ERC6909.
    /// @return assetId The underlying internal uint128 assetId.
    function assetToId(address asset, uint256 tokenId) external view returns (AssetId assetId);

    /// @notice Returns poolId and shareClassId given a share token address
    /// @dev Reverts if share token does not exist
    /// @param shareToken_ The address of the share token
    /// @return poolId The pool id associated with the share token
    /// @return scId The share class id associated with the share token
    function shareTokenDetails(address shareToken_) external view returns (PoolId poolId, ShareClassId scId);

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

    /// @notice Returns both prices per pool for a given pool, share class and asset
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id
    /// @param checkValidity Whether to check if the prices are valid
    /// @return pricePoolPerAsset The pool price per asset unit
    /// @return pricePoolPerShare The pool price per share unit
    function pricesPoolPer(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        external
        view
        returns (D18 pricePoolPerAsset, D18 pricePoolPerShare);

    /// @notice Returns the age related markers for a share class price
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @return computedAt The timestamp when this price was computed
    /// @return maxAge The maximum age this price is allowed to have
    /// @return validUntil The timestamp until this price is valid
    function markersPricePoolPerShare(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil);

    /// @notice Returns the age related markers for an asset price
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id
    /// @return computedAt The timestamp when this price was computed
    /// @return maxAge The maximum age this price is allowed to have
    /// @return validUntil The timestamp until this price is valid
    function markersPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil);

    /// @notice Returns the request manager for a given pool
    /// @param poolId The pool id
    /// @return manager The request manager for the pool
    function requestManager(PoolId poolId) external view returns (IRequestManager manager);
}
