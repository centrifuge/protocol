// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Price} from "./types/Price.sol";
import {IShareToken} from "./interfaces/IShareToken.sol";
import {IVault, VaultKind} from "./interfaces/IVault.sol";
import {IVaultFactory} from "./factories/interfaces/IVaultFactory.sol";
import {AssetIdKey, Pool, ShareClassDetails, VaultDetails, ISpokeRegistry} from "./interfaces/ISpokeRegistry.sol";

import {Auth} from "../../misc/Auth.sol";
import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../types/PoolId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {newAssetId, AssetId} from "../types/AssetId.sol";
import {IRequestManager} from "../interfaces/IRequestManager.sol";

/// @title  SpokeRegistry
/// @notice This contract stores pool, share class, asset, and price state for the spoke side.
contract SpokeRegistry is Auth, ISpokeRegistry {
    // Pools & share classes
    mapping(PoolId => Pool) public pool;
    mapping(PoolId => IRequestManager) public requestManager;
    mapping(PoolId => mapping(ShareClassId => ShareClassDetails)) public shareClass;

    // Roles
    mapping(PoolId => mapping(address => bool)) public bridger;

    // Assets & prices
    uint64 internal _assetCounter;
    mapping(AssetId => AssetIdKey) internal _idToAsset;
    mapping(address asset => mapping(uint256 tokenId => AssetId)) internal _assetToId;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => Price))) internal _pricePoolPerAsset;

    // Vaults
    mapping(IVault => VaultDetails) internal _vaultDetails;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(IRequestManager => IVault)))) public vault;

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

        _linkToken(poolId, scId, shareToken_);
    }

    /// @inheritdoc ISpokeRegistry
    function linkToken(PoolId poolId, ShareClassId scId, IShareToken shareToken_) external auth {
        _linkToken(poolId, scId, shareToken_);
    }

    function _linkToken(PoolId poolId, ShareClassId scId, IShareToken shareToken_) internal {
        shareClass[poolId][scId].shareToken = shareToken_;
        emit AddShareClass(poolId, scId, shareToken_);
    }

    /// @inheritdoc ISpokeRegistry
    function setRequestManager(PoolId poolId, IRequestManager manager_) external auth {
        require(isPoolActive(poolId), InvalidPool());
        requestManager[poolId] = manager_;
        emit SetRequestManager(poolId, manager_);
    }

    //----------------------------------------------------------------------------------------------
    // Roles
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeRegistry
    function updateBridger(PoolId poolId, address who, bool canBridge) external auth {
        bridger[poolId][who] = canBridge;
        emit UpdateBridger(poolId, who, canBridge);
    }

    //----------------------------------------------------------------------------------------------
    // Vault management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeRegistry
    function registerVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        IVaultFactory factory,
        IVault vault_
    ) external auth {
        require(vault_.poolId() == poolId, InvalidVault());
        require(vault_.scId() == scId, InvalidVault());

        // We need to check if there's a request manager for async vaults
        if (vault_.vaultKind() == VaultKind.Async) {
            require(address(requestManager[poolId]) != address(0), InvalidRequestManager());
        }

        _vaultDetails[vault_] = VaultDetails(assetId, asset, tokenId, false);
        emit DeployVault(poolId, scId, asset, tokenId, factory, vault_, vault_.vaultKind());
    }

    /// @inheritdoc ISpokeRegistry
    function linkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault_) external auth {
        require(vault_.poolId() == poolId, InvalidVault());
        require(vault_.scId() == scId, InvalidVault());

        (address asset, uint256 tokenId) = idToAsset(assetId);

        VaultDetails storage vaultDetails_ = _vaultDetails[vault_];
        require(vaultDetails_.asset != address(0), UnknownVault());
        require(!vaultDetails_.isLinked, AlreadyLinkedVault());

        vault[poolId][scId][assetId][requestManager[poolId]] = vault_;
        vaultDetails_.isLinked = true;

        if (tokenId == 0) {
            _setShareTokenVault(poolId, scId, asset, address(vault_));
        }

        emit LinkVault(poolId, scId, asset, tokenId, vault_);
    }

    /// @inheritdoc ISpokeRegistry
    function unlinkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault_) external auth {
        require(vault_.poolId() == poolId, InvalidVault());
        require(vault_.scId() == scId, InvalidVault());

        (address asset, uint256 tokenId) = idToAsset(assetId);

        VaultDetails storage vaultDetails_ = _vaultDetails[vault_];
        require(vaultDetails_.asset != address(0), UnknownVault());
        require(vaultDetails_.isLinked, AlreadyUnlinkedVault());

        delete vault[poolId][scId][assetId][requestManager[poolId]];
        vaultDetails_.isLinked = false;

        if (tokenId == 0) {
            _setShareTokenVault(poolId, scId, asset, address(0));
        }

        emit UnlinkVault(poolId, scId, asset, tokenId, vault_);
    }

    function _setShareTokenVault(PoolId poolId, ShareClassId scId, address asset, address vaultAddress) internal {
        IShareToken token = shareToken(poolId, scId);
        token.updateVault(asset, vaultAddress);
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
        require(computedAt >= poolPerShare.computedAt, CannotSetOlderPrice());

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

        poolPerAsset.price = price;
        poolPerAsset.computedAt = computedAt;
        emit UpdateAssetPrice(poolId, scId, asset, tokenId, price, computedAt);
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
    function idToAssetOrNull(AssetId assetId) external view returns (address asset, uint256 tokenId) {
        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        return (assetIdKey.asset, assetIdKey.tokenId);
    }

    /// @inheritdoc ISpokeRegistry
    function assetToId(address asset, uint256 tokenId) public view returns (AssetId assetId) {
        assetId = _assetToId[asset][tokenId];
        require(assetId.raw() != 0, UnknownAsset());
    }

    /// @inheritdoc ISpokeRegistry
    function assetToIdOrNull(address asset, uint256 tokenId) external view returns (AssetId assetId) {
        return _assetToId[asset][tokenId];
    }

    /// @inheritdoc ISpokeRegistry
    function vaultDetails(IVault vault_) public view returns (VaultDetails memory details) {
        details = _vaultDetails[vault_];
        require(details.asset != address(0), UnknownVault());
    }

    /// @inheritdoc ISpokeRegistry
    function isLinked(IVault vault_) public view returns (bool) {
        return _vaultDetails[vault_].isLinked;
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
    function pricePoolPerShareComputedAt(PoolId poolId, ShareClassId scId) external view returns (uint64) {
        return shareClass[poolId][scId].pricePoolPerShare.computedAt;
    }

    /// @inheritdoc ISpokeRegistry
    function pricePoolPerAssetComputedAt(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint64)
    {
        return _pricePoolPerAsset[poolId][scId][assetId].computedAt;
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
