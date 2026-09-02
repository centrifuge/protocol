// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Price} from "./types/Price.sol";
import {IRegistrar} from "./interfaces/IRegistrar.sol";
import {IVaultFactory} from "./factories/interfaces/IVaultFactory.sol";
import {ISpokeRequestManager} from "./interfaces/ISpokeRequestManager.sol";
import {
    AssetIdKey,
    Pool,
    ShareClassDetails,
    TokenDetails,
    VaultDetails,
    PolicyInfo,
    ISpokeRegistry
} from "./interfaces/ISpokeRegistry.sol";

import {Auth} from "../../misc/Auth.sol";
import {D18} from "../../misc/types/D18.sol";
import {IERC20} from "../../misc/interfaces/IERC20.sol";

import {PoolId} from "../types/PoolId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {IPolicy} from "../utils/interfaces/IPolicy.sol";
import {newAssetId, AssetId} from "../types/AssetId.sol";

/// @title  SpokeRegistry
/// @notice This contract stores pool, share class, asset, and price state for the spoke side. It also holds
///         the spoke pool-policy state: the installed policy contract and a consume-only authorization ledger. The
///         spoke keeps no local timelock; authorizations arrive already matured from the Hub (see {authorize}).
contract SpokeRegistry is Auth, ISpokeRegistry {
    // Pools & share classes
    mapping(PoolId => Pool) public pool;
    mapping(address token => TokenDetails) public tokenDetails;
    mapping(PoolId => ISpokeRequestManager) public requestManager;
    mapping(PoolId => mapping(ShareClassId => ShareClassDetails)) public shareClass;

    // Roles
    mapping(PoolId => mapping(address => bool)) public manager;
    mapping(PoolId => mapping(address => bool)) public bridger;

    // Policy
    mapping(PoolId => PolicyInfo) internal _policy;
    mapping(bytes32 authId => uint256 count) public authorizations;

    // Assets & prices
    uint64 internal _assetCounter;
    mapping(AssetId => AssetIdKey) internal _idToAsset;
    mapping(address asset => mapping(uint256 tokenId => AssetId)) internal _assetToId;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => Price))) internal _pricePoolPerAsset;

    // Vaults
    mapping(address vault => VaultDetails) internal _vaultDetails;

    constructor(address deployer) Auth(deployer) {}

    //----------------------------------------------------------------------------------------------
    // Pool & share class management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeRegistry
    function addPool(PoolId poolId) external auth {
        require(!poolId.isNull(), InvalidPool());
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
        require(isPoolActive(poolId), InvalidPool());
        _linkToken(poolId, scId, shareToken_, registrar_);
    }

    function _linkToken(PoolId poolId, ShareClassId scId, address shareToken_, IRegistrar registrar_) internal {
        // Must already be deployed, so a registrar cannot reserve another pool's future token address
        require(shareToken_.code.length > 0, NotAContract());
        require(address(registrar_) != address(0), EmptyRegistrar());

        ShareClassDetails storage shareClass_ = shareClass[poolId][scId];
        // Retire the outgoing token's reverse lookup before the uniqueness check, so relinking the same
        // token with a new registrar is allowed (swap the registrar, keep the token address). Reordered
        // relative to the check so the same-token case does not trip TokenAlreadyRegistered on itself.
        if (address(shareClass_.shareToken) != address(0)) delete tokenDetails[address(shareClass_.shareToken)];

        require(tokenDetails[shareToken_].poolId.isNull(), TokenAlreadyRegistered());

        shareClass_.shareToken = IERC20(shareToken_);
        shareClass_.registrar = registrar_;
        tokenDetails[shareToken_] = TokenDetails(poolId, scId);
        emit AddShareClass(poolId, scId, shareToken_, registrar_);
    }

    /// @inheritdoc ISpokeRegistry
    function setRequestManager(PoolId poolId, ISpokeRequestManager manager_) external auth {
        require(isPoolActive(poolId), InvalidPool());
        requestManager[poolId] = manager_;
        emit SetRequestManager(poolId, manager_);
    }

    /// @inheritdoc ISpokeRegistry
    function isPoolActive(PoolId poolId) public view returns (bool) {
        return pool[poolId].createdAt > 0;
    }

    /// @inheritdoc ISpokeRegistry
    function hasShareClass(PoolId poolId, ShareClassId scId) public view returns (bool) {
        return address(shareClass[poolId][scId].shareToken) != address(0);
    }

    /// @inheritdoc ISpokeRegistry
    function shareToken(PoolId poolId, ShareClassId scId) public view returns (IERC20) {
        return shareClass[poolId][scId].shareToken;
    }

    /// @inheritdoc ISpokeRegistry
    function shareTokenAndRegistrar(PoolId poolId, ShareClassId scId)
        public
        view
        returns (IERC20 token, IRegistrar registrar_)
    {
        ShareClassDetails storage shareClass_ = shareClass[poolId][scId];
        return (shareClass_.shareToken, shareClass_.registrar);
    }

    //----------------------------------------------------------------------------------------------
    // Roles
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeRegistry
    function updateManager(PoolId poolId, address who, bool canManage) external auth {
        require(isPoolActive(poolId), InvalidPool());
        manager[poolId][who] = canManage;
        emit UpdateManager(poolId, who, canManage);
    }

    /// @inheritdoc ISpokeRegistry
    function updateBridger(PoolId poolId, address who, bool canBridge) external auth {
        require(isPoolActive(poolId), InvalidPool());
        bridger[poolId][who] = canBridge;
        emit UpdateBridger(poolId, who, canBridge);
    }

    //----------------------------------------------------------------------------------------------
    // Policy & authorization
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeRegistry
    function setPolicy(PoolId poolId, IPolicy policy_) external auth {
        require(isPoolActive(poolId), InvalidPool());
        _policy[poolId] = PolicyInfo(policy_, _policy[poolId].nonce + 1);
        emit SetPolicy(poolId, policy_);
    }

    /// @inheritdoc ISpokeRegistry
    function authorize(PoolId poolId, bytes calldata data) external auth {
        PolicyInfo memory info = _policy[poolId];
        require(address(info.policy) != address(0), PolicyNotInstalled());

        bytes32 id = _authId(poolId, address(info.policy), info.nonce, data);
        authorizations[id]++;
        emit AuthorizationGranted(poolId, id, data);
    }

    /// @inheritdoc ISpokeRegistry
    function unauthorize(PoolId poolId, bytes calldata data) external auth {
        PolicyInfo memory info = _policy[poolId];
        bytes32 id = _authId(poolId, address(info.policy), info.nonce, data);
        uint256 count = authorizations[id];
        require(count != 0, NoOutstandingAuthorization());

        authorizations[id] = count - 1;
        emit AuthorizationRevoked(poolId, id, data);
    }

    /// @inheritdoc ISpokeRegistry
    function consumeAuthorization(PoolId poolId, address caller, bytes calldata data) external {
        PolicyInfo memory info = _policy[poolId];
        require(msg.sender == address(info.policy), CallerNotPolicy());

        bytes32 id = _authId(poolId, address(info.policy), info.nonce, data);
        uint256 count = authorizations[id];
        require(count != 0, NoOutstandingAuthorization());

        authorizations[id] = count - 1;
        emit AuthorizationConsumed(poolId, caller, id);
    }

    /// @inheritdoc ISpokeRegistry
    /// @dev Namespaced by the pool's current policy and its install nonce, so any policy change (even
    ///      swapping back to a previously used policy) makes every outstanding authorization unreachable.
    function authId(PoolId poolId, bytes calldata data) external view returns (bytes32) {
        PolicyInfo memory info = _policy[poolId];
        return _authId(poolId, address(info.policy), info.nonce, data);
    }

    function _authId(PoolId poolId, address policy_, uint64 nonce_, bytes calldata data)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(poolId.raw(), policy_, nonce_, data));
    }

    /// @inheritdoc ISpokeRegistry
    function policy(PoolId poolId) external view returns (IPolicy) {
        return _policy[poolId].policy;
    }

    /// @inheritdoc ISpokeRegistry
    function policyNonce(PoolId poolId) external view returns (uint64) {
        return _policy[poolId].nonce;
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
        address vault_,
        bytes calldata payload
    ) external auth {
        require(hasShareClass(poolId, scId), ShareTokenDoesNotExist());

        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        require(assetIdKey.asset != address(0), UnknownAsset());
        require(assetIdKey.asset == asset && assetIdKey.tokenId == tokenId, UnknownAsset());

        require(_vaultDetails[vault_].asset == address(0), AlreadyRegisteredVault());
        require(vault_.code.length > 0, NotAContract());

        _vaultDetails[vault_] = VaultDetails(poolId, scId, assetId, asset, tokenId, false);
        emit DeployVault(poolId, scId, asset, tokenId, factory, vault_, payload);
    }

    /// @inheritdoc ISpokeRegistry
    function linkVault(PoolId poolId, ShareClassId scId, AssetId assetId, address vault_) external auth {
        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        require(assetIdKey.asset != address(0), UnknownAsset());

        VaultDetails storage vaultDetails_ = _vaultDetails[vault_];
        require(!vaultDetails_.isLinked, AlreadyLinkedVault());
        require(vaultDetails_.asset != address(0), UnknownVault());
        require(vaultDetails_.assetId.raw() == assetId.raw(), UnknownAsset());
        require(vaultDetails_.poolId == poolId && vaultDetails_.scId == scId, InvalidVault());

        vaultDetails_.isLinked = true;

        emit LinkVault(poolId, scId, assetIdKey.asset, assetIdKey.tokenId, vault_);
    }

    /// @inheritdoc ISpokeRegistry
    function unlinkVault(PoolId poolId, ShareClassId scId, AssetId assetId, address vault_) external auth {
        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        require(assetIdKey.asset != address(0), UnknownAsset());

        VaultDetails storage vaultDetails_ = _vaultDetails[vault_];
        require(vaultDetails_.isLinked, AlreadyUnlinkedVault());
        require(vaultDetails_.assetId.raw() == assetId.raw(), UnknownAsset());
        require(vaultDetails_.poolId == poolId && vaultDetails_.scId == scId, InvalidVault());

        vaultDetails_.isLinked = false;

        emit UnlinkVault(poolId, scId, assetIdKey.asset, assetIdKey.tokenId, vault_);
    }

    /// @inheritdoc ISpokeRegistry
    function isVaultRegistered(address vault_) public view returns (bool) {
        return _vaultDetails[vault_].asset != address(0);
    }

    /// @inheritdoc ISpokeRegistry
    function vaultDetails(address vault_) public view returns (VaultDetails memory details) {
        return _vaultDetails[vault_];
    }

    /// @inheritdoc ISpokeRegistry
    function isLinked(address vault_) public view returns (bool) {
        return _vaultDetails[vault_].isLinked;
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
        require(asset != address(0), UnknownAsset());
        require(centrifugeId != 0, InvalidCentrifugeId());
        require(_assetToId[asset][tokenId].isNull(), AssetAlreadyRegistered());

        _assetCounter++;
        assetId = newAssetId(centrifugeId, _assetCounter);

        _idToAsset[assetId] = AssetIdKey(asset, tokenId);
        _assetToId[asset][tokenId] = assetId;
    }

    /// @inheritdoc ISpokeRegistry
    function isRegistered(AssetId assetId) public view returns (bool) {
        return _idToAsset[assetId].asset != address(0);
    }

    /// @inheritdoc ISpokeRegistry
    function idToAsset(AssetId assetId) public view returns (address asset, uint256 tokenId) {
        return idToAsset(assetId, false);
    }

    /// @inheritdoc ISpokeRegistry
    function idToAsset(AssetId assetId, bool revertOnNull) public view returns (address asset, uint256 tokenId) {
        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        require(!revertOnNull || assetIdKey.asset != address(0), UnknownAsset());
        return (assetIdKey.asset, assetIdKey.tokenId);
    }

    /// @inheritdoc ISpokeRegistry
    function assetToId(address asset, uint256 tokenId) public view returns (AssetId assetId) {
        return assetToId(asset, tokenId, false);
    }

    /// @inheritdoc ISpokeRegistry
    function assetToId(address asset, uint256 tokenId, bool revertOnNull) public view returns (AssetId assetId) {
        assetId = _assetToId[asset][tokenId];
        require(!revertOnNull || !assetId.isNull(), UnknownAsset());
    }

    //----------------------------------------------------------------------------------------------
    // Price management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeRegistry
    function updatePricePoolPerShare(PoolId poolId, ShareClassId scId, D18 price, uint64 computedAt) external auth {
        require(hasShareClass(poolId, scId), ShareTokenDoesNotExist());
        Price storage poolPerShare = shareClass[poolId][scId].pricePoolPerShare;
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
        require(hasShareClass(poolId, scId), ShareTokenDoesNotExist());
        require(isRegistered(assetId), UnknownAsset());
        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        Price storage poolPerAsset = _pricePoolPerAsset[poolId][scId][assetId];
        require(computedAt >= poolPerAsset.computedAt, CannotSetOlderPrice());

        poolPerAsset.price = price;
        poolPerAsset.computedAt = computedAt;
        emit UpdateAssetPrice(poolId, scId, assetIdKey.asset, assetIdKey.tokenId, price, computedAt);
    }

    /// @inheritdoc ISpokeRegistry
    function pricePoolPerShare(PoolId poolId, ShareClassId scId, bool checkValidity) public view returns (D18 price) {
        Price storage poolPerShare = shareClass[poolId][scId].pricePoolPerShare;
        require(!checkValidity || poolPerShare.isValid(), InvalidPrice());

        return poolPerShare.price;
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
}
