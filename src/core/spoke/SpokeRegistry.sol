// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Price} from "./types/Price.sol";
import {IShareToken} from "./interfaces/IShareToken.sol";
import {AssetIdKey, Pool, ShareClassDetails, TokenDetails, ISpokeRegistry} from "./interfaces/ISpokeRegistry.sol";

import {Auth} from "../../misc/Auth.sol";
import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../types/PoolId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {newAssetId, AssetId} from "../types/AssetId.sol";
import {IRequestManager} from "../interfaces/IRequestManager.sol";

/// @title  SpokeRegistry
/// @notice This contract stores pool, share class, asset, and price state for the spoke side.
contract SpokeRegistry is Auth, ISpokeRegistry {
    mapping(PoolId => Pool) public pool;
    mapping(PoolId => IRequestManager) public requestManager;
    mapping(PoolId => mapping(ShareClassId => ShareClassDetails)) public shareClass;

    uint64 internal _assetCounter;
    mapping(AssetId => AssetIdKey) internal _idToAsset;
    mapping(address token => TokenDetails) internal _tokenDetails;
    mapping(address asset => mapping(uint256 tokenId => AssetId)) internal _assetToId;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => Price))) internal _pricePoolPerAsset;

    constructor(address deployer) Auth(deployer) {}

    //----------------------------------------------------------------------------------------------
    // Pool & share class management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeRegistry
    function addPool(PoolId poolId) external auth {
        Pool storage pool_ = pool[poolId];
        require(pool_.createdAt == 0, PoolAlreadyAdded());
        pool_.createdAt = uint64(block.timestamp);

        emit AddPool(poolId);
    }

    /// @inheritdoc ISpokeRegistry
    function addShareClass(PoolId poolId, ShareClassId scId, IShareToken shareToken_) external auth {
        require(isPoolActive(poolId), InvalidPool());
        require(address(shareClass[poolId][scId].shareToken) == address(0), ShareClassAlreadyRegistered());

        shareClass[poolId][scId].shareToken = shareToken_;
        _tokenDetails[address(shareToken_)] = TokenDetails(poolId, scId);
        emit AddShareClass(poolId, scId, shareToken_);
    }

    /// @inheritdoc ISpokeRegistry
    function linkToken(PoolId poolId, ShareClassId scId, IShareToken shareToken_) external auth {
        shareClass[poolId][scId].shareToken = shareToken_;
        _tokenDetails[address(shareToken_)] = TokenDetails(poolId, scId);
        emit AddShareClass(poolId, scId, shareToken_);
    }

    /// @inheritdoc ISpokeRegistry
    function setShareTokenVault(PoolId poolId, ShareClassId scId, address asset, address vault) external auth {
        IShareToken token = shareToken(poolId, scId);
        token.updateVault(asset, vault);
    }

    /// @inheritdoc ISpokeRegistry
    function setRequestManager(PoolId poolId, IRequestManager manager) external auth {
        require(isPoolActive(poolId), InvalidPool());
        requestManager[poolId] = manager;
        emit SetRequestManager(poolId, manager);
    }

    //----------------------------------------------------------------------------------------------
    // Asset management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeRegistry
    function createAssetId(uint16 centrifugeId, address asset, uint256 tokenId)
        external
        auth
        returns (AssetId assetId)
    {
        _assetCounter++;
        assetId = newAssetId(centrifugeId, _assetCounter);

        _idToAsset[assetId] = AssetIdKey(asset, tokenId);
        _assetToId[asset][tokenId] = assetId;
    }

    //----------------------------------------------------------------------------------------------
    // Price management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeRegistry
    function updatePricePoolPerShare(PoolId poolId, ShareClassId scId, D18 price, uint64 computedAt) external auth {
        ShareClassDetails storage shareClass_ = _shareClass(poolId, scId);
        Price storage poolPerShare = shareClass_.pricePoolPerShare;
        require(computedAt >= shareClass_.pricePoolPerShare.computedAt, CannotSetOlderPrice());

        // Disable expiration of the price if never initialized
        if (poolPerShare.computedAt == 0 && poolPerShare.maxAge == 0) {
            poolPerShare.maxAge = type(uint64).max;
        }

        poolPerShare.price = price;
        poolPerShare.computedAt = computedAt;
        emit UpdateSharePrice(poolId, scId, price, computedAt);
    }

    /// @inheritdoc ISpokeRegistry
    function updatePricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, D18 price, uint64 computedAt)
        external
        auth
    {
        (address asset, uint256 tokenId) = idToAsset(assetId);
        Price storage poolPerAsset = _pricePoolPerAsset[poolId][scId][assetId];
        require(computedAt >= poolPerAsset.computedAt, CannotSetOlderPrice());

        // Disable expiration of the price if never initialized
        if (poolPerAsset.computedAt == 0 && poolPerAsset.maxAge == 0) {
            poolPerAsset.maxAge = type(uint64).max;
        }

        poolPerAsset.price = price;
        poolPerAsset.computedAt = computedAt;
        emit UpdateAssetPrice(poolId, scId, asset, tokenId, price, computedAt);
    }

    /// @inheritdoc ISpokeRegistry
    function setMaxSharePriceAge(PoolId poolId, ShareClassId scId, uint64 maxPriceAge) external auth {
        ShareClassDetails storage shareClass_ = _shareClass(poolId, scId);
        shareClass_.pricePoolPerShare.maxAge = maxPriceAge;
        emit UpdateMaxSharePriceAge(poolId, scId, maxPriceAge);
    }

    /// @inheritdoc ISpokeRegistry
    function setMaxAssetPriceAge(PoolId poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge) external auth {
        (address asset, uint256 tokenId) = idToAsset(assetId);
        _pricePoolPerAsset[poolId][scId][assetId].maxAge = maxPriceAge;
        emit UpdateMaxAssetPriceAge(poolId, scId, asset, tokenId, maxPriceAge);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeRegistry
    function isPoolActive(PoolId poolId) public view returns (bool) {
        return pool[poolId].createdAt > 0;
    }

    /// @inheritdoc ISpokeRegistry
    function shareToken(PoolId poolId, ShareClassId scId) public view returns (IShareToken) {
        return _shareClass(poolId, scId).shareToken;
    }

    /// @inheritdoc ISpokeRegistry
    function idToAsset(AssetId assetId) public view returns (address asset, uint256 tokenId) {
        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        require(assetIdKey.asset != address(0), UnknownAsset());
        return (assetIdKey.asset, assetIdKey.tokenId);
    }

    /// @inheritdoc ISpokeRegistry
    function assetToId(address asset, uint256 tokenId) public view returns (AssetId assetId) {
        assetId = _assetToId[asset][tokenId];
        require(assetId.raw() != 0, UnknownAsset());
    }

    /// @inheritdoc ISpokeRegistry
    function shareTokenDetails(address shareToken_) public view returns (PoolId poolId, ShareClassId scId) {
        TokenDetails storage details = _tokenDetails[shareToken_];
        poolId = details.poolId;
        scId = details.scId;
        require(!poolId.isNull() && !scId.isNull(), ShareTokenDoesNotExist());
    }

    /// @inheritdoc ISpokeRegistry
    function pricePoolPerShare(PoolId poolId, ShareClassId scId, bool checkValidity) public view returns (D18 price) {
        ShareClassDetails storage shareClass_ = _shareClass(poolId, scId);
        require(!checkValidity || shareClass_.pricePoolPerShare.isValid(), InvalidPrice());

        return shareClass_.pricePoolPerShare.price;
    }

    /// @inheritdoc ISpokeRegistry
    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        public
        view
        returns (D18 price)
    {
        Price memory poolPerAsset = _pricePoolPerAsset[poolId][scId][assetId];
        require(!checkValidity || poolPerAsset.isValid(), InvalidPrice());

        return poolPerAsset.price;
    }

    /// @inheritdoc ISpokeRegistry
    function pricesPoolPer(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        public
        view
        returns (D18 pricePoolPerAsset_, D18 pricePoolPerShare_)
    {
        ShareClassDetails storage shareClass_ = _shareClass(poolId, scId);

        Price memory poolPerAsset = _pricePoolPerAsset[poolId][scId][assetId];
        Price memory poolPerShare = shareClass_.pricePoolPerShare;

        require(!checkValidity || poolPerAsset.isValid() && poolPerShare.isValid(), InvalidPrice());

        return (poolPerAsset.price, poolPerShare.price);
    }

    /// @inheritdoc ISpokeRegistry
    function markersPricePoolPerShare(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil)
    {
        ShareClassDetails storage shareClass_ = _shareClass(poolId, scId);
        computedAt = shareClass_.pricePoolPerShare.computedAt;
        maxAge = shareClass_.pricePoolPerShare.maxAge;
        validUntil = shareClass_.pricePoolPerShare.validUntil();
    }

    /// @inheritdoc ISpokeRegistry
    function markersPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil)
    {
        Price memory poolPerAsset = _pricePoolPerAsset[poolId][scId][assetId];
        computedAt = poolPerAsset.computedAt;
        maxAge = poolPerAsset.maxAge;
        validUntil = poolPerAsset.validUntil();
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    function _shareClass(PoolId poolId, ShareClassId scId)
        internal
        view
        returns (ShareClassDetails storage shareClass_)
    {
        shareClass_ = shareClass[poolId][scId];
        require(address(shareClass_.shareToken) != address(0), ShareTokenDoesNotExist());
    }
}
