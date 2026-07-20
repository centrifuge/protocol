// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Price} from "./types/Price.sol";
import {IRegistrar} from "./interfaces/IRegistrar.sol";
import {IVault, VaultKind} from "./interfaces/IVault.sol";
import {IVaultFactory} from "./factories/interfaces/IVaultFactory.sol";
import {
    AssetIdKey,
    Pool,
    ShareClassDetails,
    TokenDetails,
    VaultDetails,
    ISpokeRegistry
} from "./interfaces/ISpokeRegistry.sol";

import {Auth} from "../../misc/Auth.sol";
import {D18} from "../../misc/types/D18.sol";
import {IERC20} from "../../misc/interfaces/IERC20.sol";

import {PoolId} from "../types/PoolId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {newAssetId, AssetId} from "../types/AssetId.sol";
import {IManifest} from "../hub/interfaces/IManifest.sol";
import {IRequestManager} from "../interfaces/IRequestManager.sol";

/// @title  SpokeRegistry
/// @notice This contract stores pool, share class, asset, and price state for the spoke side. It also holds
///         the spoke pool-policy state: the installed manifest and a consume-only authorization ledger. The
///         spoke keeps no local timelock; authorizations arrive already matured from the Hub (see {authorize}).
contract SpokeRegistry is Auth, ISpokeRegistry {
    // Pools & share classes
    mapping(PoolId => Pool) public pool;
    mapping(PoolId => IRequestManager) public requestManager;
    mapping(address token => TokenDetails) internal _tokenDetails;
    mapping(PoolId => mapping(ShareClassId => ShareClassDetails)) public shareClass;

    // Roles
    mapping(PoolId => mapping(address => bool)) public manager;
    mapping(PoolId => mapping(address => bool)) public bridger;

    // Policy
    mapping(PoolId => IManifest) public manifest;
    mapping(bytes32 authId => uint256 count) public authorizations;

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
    function addShareClass(PoolId poolId, ShareClassId scId, address shareToken_, IRegistrar registrar_) external auth {
        require(isPoolActive(poolId), InvalidPool());
        require(address(shareClass[poolId][scId].shareToken) == address(0), ShareClassAlreadyRegistered());

        _linkToken(poolId, scId, shareToken_, registrar_);
    }

    /// @inheritdoc ISpokeRegistry
    function linkToken(PoolId poolId, ShareClassId scId, address shareToken_, IRegistrar registrar_) external auth {
        _linkToken(poolId, scId, shareToken_, registrar_);
    }

    function _linkToken(PoolId poolId, ShareClassId scId, address shareToken_, IRegistrar registrar_) internal {
        // Must already be deployed, so a registrar cannot reserve another pool's future token address
        require(shareToken_.code.length > 0, NotAContract());
        require(_tokenDetails[shareToken_].poolId.isNull(), TokenAlreadyRegistered());

        ShareClassDetails storage shareClass_ = shareClass[poolId][scId];
        shareClass_.shareToken = IERC20(shareToken_);
        shareClass_.registrar = registrar_;
        _tokenDetails[shareToken_] = TokenDetails(poolId, scId);
        emit AddShareClass(poolId, scId, shareToken_, registrar_);
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
    function updateManager(PoolId poolId, address who, bool canManage) external auth {
        manager[poolId][who] = canManage;
        emit UpdateManager(poolId, who, canManage);
    }

    /// @inheritdoc ISpokeRegistry
    function updateBridger(PoolId poolId, address who, bool canBridge) external auth {
        bridger[poolId][who] = canBridge;
        emit UpdateBridger(poolId, who, canBridge);
    }

    /// @inheritdoc ISpokeRegistry
    function setManifest(PoolId poolId, IManifest manifest_) external auth {
        manifest[poolId] = manifest_;
        emit SetManifest(poolId, manifest_);
    }

    /// @inheritdoc ISpokeRegistry
    function authorize(PoolId poolId, bytes calldata data) external auth {
        // The Hub already ran the timelock, so the spoke just counts the call as authorized. A counter (not
        // a flag) lets several authorizations of the same call be outstanding; a matching call later consumes one.
        IManifest m = manifest[poolId];
        require(address(m) != address(0), NoManifest());

        bytes32 id = _authId(poolId, address(m), data);
        authorizations[id]++;
        emit Authorized(poolId, id, data);
    }

    /// @inheritdoc ISpokeRegistry
    function unauthorize(PoolId poolId, bytes calldata data) external auth {
        // Lets the Hub revoke an outstanding, not-yet-consumed authorization (decrements the counter).
        bytes32 id = _authId(poolId, address(manifest[poolId]), data);
        uint256 count = authorizations[id];
        require(count != 0, Unauthorized());
        authorizations[id] = count - 1;
        emit AuthorizationRevoked(poolId, id, data);
    }

    /// @inheritdoc ISpokeRegistry
    function consumeAuthorization(PoolId poolId, address caller, bytes calldata data) external {
        IManifest m = manifest[poolId];
        require(msg.sender == address(m), NotManifest());

        bytes32 id = _authId(poolId, address(m), data);
        uint256 count = authorizations[id];
        require(count != 0, Unauthorized());
        authorizations[id] = count - 1;
        emit AuthorizationConsumed(poolId, caller, id);
    }

    function _authId(PoolId poolId, address manifest_, bytes calldata data) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId.raw(), manifest_, data));
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
        require(address(vault[poolId][scId][assetId][requestManager[poolId]]) == address(0), AlreadyLinkedVault());

        vault[poolId][scId][assetId][requestManager[poolId]] = vault_;
        vaultDetails_.isLinked = true;

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
        require(vault[poolId][scId][assetId][requestManager[poolId]] == vault_, AlreadyUnlinkedVault());

        delete vault[poolId][scId][assetId][requestManager[poolId]];
        vaultDetails_.isLinked = false;

        emit UnlinkVault(poolId, scId, asset, tokenId, vault_);
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
    function shareToken(PoolId poolId, ShareClassId scId) public view returns (IERC20) {
        return _shareClass(poolId, scId).shareToken;
    }

    /// @inheritdoc ISpokeRegistry
    /// @dev Existence is checked against the registrar slot (set atomically with the token in `_linkToken`),
    ///      so this reads a single slot instead of also loading the token as `_shareClass` would.
    function registrar(PoolId poolId, ShareClassId scId) public view returns (IRegistrar registrar_) {
        registrar_ = shareClass[poolId][scId].registrar;
        require(address(registrar_) != address(0), ShareTokenDoesNotExist());
    }

    /// @inheritdoc ISpokeRegistry
    function shareTokenAndRegistrar(PoolId poolId, ShareClassId scId)
        public
        view
        returns (IERC20 token, IRegistrar registrar_)
    {
        ShareClassDetails storage shareClass_ = _shareClass(poolId, scId);
        return (shareClass_.shareToken, shareClass_.registrar);
    }

    /// @inheritdoc ISpokeRegistry
    function shareTokenDetails(address shareToken_) public view returns (PoolId poolId, ShareClassId scId) {
        TokenDetails storage details = _tokenDetails[shareToken_];
        poolId = details.poolId;
        scId = details.scId;
        require(!poolId.isNull(), ShareTokenDoesNotExist());
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
