// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Price} from "./types/Price.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IShareToken} from "./interfaces/IShareToken.sol";
import {IVaultManager} from "./interfaces/IVaultManager.sol";
import {ITokenFactory} from "./factories/interfaces/ITokenFactory.sol";
import {IVaultFactory} from "./factories/interfaces/IVaultFactory.sol";
import {AssetIdKey, Pool, ShareClassDetails, ShareClassAsset, VaultDetails, ISpoke} from "./interfaces/ISpoke.sol";

import {Auth} from "../misc/Auth.sol";
import {D18} from "../misc/types/D18.sol";
import {Recoverable} from "../misc/Recoverable.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";
import {IERC165} from "../misc/interfaces/IERC7575.sol";
import {IERC20Metadata} from "../misc/interfaces/IERC20.sol";
import {IERC6909MetadataExt} from "../misc/interfaces/IERC6909.sol";
import {ReentrancyProtection} from "../misc/ReentrancyProtection.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {IGateway} from "../common/interfaces/IGateway.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";
import {newAssetId, AssetId} from "../common/types/AssetId.sol";
import {IPoolEscrow} from "../common/interfaces/IPoolEscrow.sol";
import {ITransferHook} from "../common/interfaces/ITransferHook.sol";
import {IRequestManager} from "../common/interfaces/IRequestManager.sol";
import {ISpokeMessageSender} from "../common/interfaces/IGatewaySenders.sol";
import {ISpokeGatewayHandler} from "../common/interfaces/IGatewayHandlers.sol";
import {VaultUpdateKind, MessageLib} from "../common/libraries/MessageLib.sol";
import {IPoolEscrowFactory} from "../common/factories/interfaces/IPoolEscrowFactory.sol";

/// @title  Spoke
/// @notice This contract manages which pools & share classes exist, controlling allowed pool currencies,
///         initiating cross-chain transfers for tokens, and registering and linking vaults.
contract Spoke is Auth, Recoverable, ReentrancyProtection, ISpoke, ISpokeGatewayHandler {
    using CastLib for *;
    using MessageLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;

    uint8 internal constant MIN_DECIMALS = 2;
    uint8 internal constant MAX_DECIMALS = 18;

    IGateway public gateway;
    ITokenFactory public tokenFactory;
    ISpokeMessageSender public sender;
    IPoolEscrowFactory public poolEscrowFactory;

    uint64 internal _assetCounter;

    mapping(PoolId => Pool) public pool;
    mapping(PoolId => mapping(ShareClassId scId => ShareClassDetails)) public shareClass;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => ShareClassAsset))) public assetInfo;

    mapping(IVault => VaultDetails) internal _vaultDetails;
    mapping(AssetId => AssetIdKey) internal _idToAsset;
    mapping(address asset => mapping(uint256 tokenId => AssetId assetId)) internal _assetToId;

    constructor(ITokenFactory tokenFactory_, address deployer) Auth(deployer) {
        tokenFactory = tokenFactory_;
    }

    modifier payTransaction() {
        gateway.startTransactionPayment{value: msg.value}(msg.sender);
        _;
        gateway.endTransactionPayment();
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "sender") sender = ISpokeMessageSender(data);
        else if (what == "tokenFactory") tokenFactory = ITokenFactory(data);
        else if (what == "poolEscrowFactory") poolEscrowFactory = IPoolEscrowFactory(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function crosschainTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 remoteExtraGasLimit
    ) external payable payTransaction protected {
        IShareToken share = IShareToken(shareToken(poolId, scId));
        require(centrifugeId != sender.localCentrifugeId(), LocalTransferNotAllowed());
        require(
            share.checkTransferRestriction(msg.sender, address(uint160(centrifugeId)), amount),
            CrossChainTransferNotAllowed()
        );

        share.authTransferFrom(msg.sender, msg.sender, address(this), amount);
        share.burn(address(this), amount);

        emit InitiateTransferShares(centrifugeId, poolId, scId, msg.sender, receiver, amount);
        sender.sendInitiateTransferShares(centrifugeId, poolId, scId, receiver, amount, remoteExtraGasLimit);
    }

    /// @inheritdoc ISpoke
    function registerAsset(uint16 centrifugeId, address asset, uint256 tokenId)
        external
        payable
        payTransaction
        protected
        returns (AssetId assetId)
    {
        string memory name;
        string memory symbol;
        uint8 decimals;

        decimals = _safeGetAssetDecimals(asset, tokenId);
        require(decimals >= MIN_DECIMALS, TooFewDecimals());
        require(decimals <= MAX_DECIMALS, TooManyDecimals());

        if (tokenId == 0) {
            IERC20Metadata meta = IERC20Metadata(asset);
            name = meta.name();
            symbol = meta.symbol();
        } else {
            IERC6909MetadataExt meta = IERC6909MetadataExt(asset);
            name = meta.name(tokenId);
            symbol = meta.symbol(tokenId);
        }

        assetId = _assetToId[asset][tokenId];
        bool isInitialization = assetId.raw() == 0;
        if (isInitialization) {
            _assetCounter++;
            assetId = newAssetId(sender.localCentrifugeId(), _assetCounter);

            _idToAsset[assetId] = AssetIdKey(asset, tokenId);
            _assetToId[asset][tokenId] = assetId;
        }

        emit RegisterAsset(assetId, asset, tokenId, name, symbol, decimals, isInitialization);
        sender.sendRegisterAsset(centrifugeId, assetId, decimals);
    }

    /// @inheritdoc ISpoke
    function request(PoolId poolId, ShareClassId scId, AssetId assetId, bytes memory payload) external {
        require(msg.sender == address(assetInfo[poolId][scId][assetId].manager), NotAuthorized());

        sender.sendRequest(poolId, scId, assetId, payload);
    }

    //----------------------------------------------------------------------------------------------
    // Pool & token management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeGatewayHandler
    function addPool(PoolId poolId) public auth {
        Pool storage pool_ = pool[poolId];
        require(pool_.createdAt == 0, PoolAlreadyAdded());
        pool_.createdAt = block.timestamp;

        IPoolEscrow escrow = poolEscrowFactory.escrow(poolId);
        if (address(escrow).code.length == 0) {
            poolEscrowFactory.newEscrow(poolId);
            gateway.setRefundAddress(poolId, escrow);
        }

        emit AddPool(poolId);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function addShareClass(
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        address hook
    ) public auth {
        require(isPoolActive(poolId), InvalidPool());
        require(decimals >= MIN_DECIMALS, TooFewDecimals());
        require(decimals <= MAX_DECIMALS, TooManyDecimals());
        require(address(shareClass[poolId][scId].shareToken) == address(0), ShareClassAlreadyRegistered());

        IShareToken shareToken_ = tokenFactory.newToken(name, symbol, decimals, salt);
        if (hook != address(0)) shareToken_.file("hook", hook);
        linkToken(poolId, scId, shareToken_);
    }

    /// @inheritdoc ISpoke
    function linkToken(PoolId poolId, ShareClassId scId, IShareToken shareToken_) public auth {
        shareClass[poolId][scId].shareToken = shareToken_;
        emit AddShareClass(poolId, scId, shareToken_);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function setRequestManager(PoolId poolId, ShareClassId scId, AssetId assetId, IRequestManager manager)
        public
        auth
    {
        _shareClass(poolId, scId); // Check existence
        ShareClassAsset storage assetInfo_ = assetInfo[poolId][scId][assetId];
        require(assetInfo_.numVaults == 0, MoreThanZeroLinkedVaults());
        assetInfo_.manager = manager;
        emit SetRequestManager(poolId, scId, assetId, manager);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updateShareMetadata(PoolId poolId, ShareClassId scId, string memory name, string memory symbol)
        public
        auth
    {
        IShareToken shareToken_ = shareToken(poolId, scId);
        require(
            keccak256(bytes(shareToken_.name())) != keccak256(bytes(name))
                || keccak256(bytes(shareToken_.symbol())) != keccak256(bytes(symbol)),
            OldMetadata()
        );

        shareToken_.file("name", name);
        shareToken_.file("symbol", symbol);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updateShareHook(PoolId poolId, ShareClassId scId, address hook) public auth {
        IShareToken shareToken_ = shareToken(poolId, scId);
        require(hook != shareToken_.hook(), OldHook());
        shareToken_.file("hook", hook);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updateRestriction(PoolId poolId, ShareClassId scId, bytes memory update) public auth {
        IShareToken shareToken_ = shareToken(poolId, scId);
        address hook = shareToken_.hook();
        require(hook != address(0), InvalidHook());
        ITransferHook(hook).updateRestriction(address(shareToken_), update);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function executeTransferShares(PoolId poolId, ShareClassId scId, bytes32 receiver, uint128 amount) public auth {
        IShareToken shareToken_ = shareToken(poolId, scId);
        shareToken_.mint(receiver.toAddress(), amount);
        emit ExecuteTransferShares(poolId, scId, receiver.toAddress(), amount);
    }

    //----------------------------------------------------------------------------------------------
    // Price management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeGatewayHandler
    function updatePricePoolPerShare(PoolId poolId, ShareClassId scId, D18 price, uint64 computedAt) public auth {
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

    /// @inheritdoc ISpokeGatewayHandler
    function updatePricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, D18 price, uint64 computedAt)
        public
        auth
    {
        (address asset, uint256 tokenId) = idToAsset(assetId);
        Price storage poolPerAsset = assetInfo[poolId][scId][assetId].pricePoolPerAsset;
        require(computedAt >= poolPerAsset.computedAt, CannotSetOlderPrice());

        // Disable expiration of the price if never initialized
        if (poolPerAsset.computedAt == 0 && poolPerAsset.maxAge == 0) {
            poolPerAsset.maxAge = type(uint64).max;
        }

        poolPerAsset.price = price;
        poolPerAsset.computedAt = computedAt;
        emit UpdateAssetPrice(poolId, scId, asset, tokenId, price, computedAt);
    }

    function setMaxSharePriceAge(PoolId poolId, ShareClassId scId, uint64 maxPriceAge) external auth {
        ShareClassDetails storage shareClass_ = _shareClass(poolId, scId);
        shareClass_.pricePoolPerShare.maxAge = maxPriceAge;
        emit UpdateMaxSharePriceAge(poolId, scId, maxPriceAge);
    }

    function setMaxAssetPriceAge(PoolId poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge) external auth {
        (address asset, uint256 tokenId) = idToAsset(assetId);
        assetInfo[poolId][scId][assetId].pricePoolPerAsset.maxAge = maxPriceAge;
        emit UpdateMaxAssetPriceAge(poolId, scId, asset, tokenId, maxPriceAge);
    }

    //----------------------------------------------------------------------------------------------
    // Vault management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeGatewayHandler
    function requestCallback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes memory payload) external auth {
        IRequestManager manager = assetInfo[poolId][scId][assetId].manager;
        require(address(manager) != address(0), InvalidRequestManager());

        manager.callback(poolId, scId, assetId, payload);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address vaultOrFactory,
        VaultUpdateKind kind
    ) external auth {
        if (kind == VaultUpdateKind.DeployAndLink) {
            IVault vault = deployVault(poolId, scId, assetId, IVaultFactory(vaultOrFactory));
            linkVault(poolId, scId, assetId, vault);
        } else {
            IVault vault = IVault(vaultOrFactory);

            // Needed as safeguard against non-validated vaults
            // I.e. we only accept vaults that have been deployed by the pool manager
            require(_vaultDetails[vault].asset != address(0), UnknownVault());

            if (kind == VaultUpdateKind.Link) linkVault(poolId, scId, assetId, vault);
            else if (kind == VaultUpdateKind.Unlink) unlinkVault(poolId, scId, assetId, vault);
            else revert MalformedVaultUpdateMessage(); // Unreachable due the enum check
        }
    }

    /// @inheritdoc ISpoke
    function deployVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVaultFactory factory)
        public
        auth
        returns (IVault)
    {
        ShareClassDetails storage shareClass_ = _shareClass(poolId, scId);
        (address asset, uint256 tokenId) = idToAsset(assetId);
        IVault vault = factory.newVault(poolId, scId, asset, tokenId, shareClass_.shareToken, new address[](0));
        registerVault(poolId, scId, assetId, asset, tokenId, factory, vault);

        return vault;
    }

    /// @inheritdoc ISpoke
    /// @dev Extracted from deployVault to be used in migrations
    function registerVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        IVaultFactory factory,
        IVault vault
    ) public auth {
        _vaultDetails[vault] = VaultDetails(assetId, asset, tokenId, false);
        emit DeployVault(poolId, scId, asset, tokenId, factory, vault, vault.vaultKind());
    }

    /// @inheritdoc ISpoke
    function linkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault) public auth {
        require(vault.poolId() == poolId, InvalidVault());
        require(vault.scId() == scId, InvalidVault());

        (address asset, uint256 tokenId) = idToAsset(assetId);
        ShareClassDetails storage shareClass_ = _shareClass(poolId, scId);
        VaultDetails storage vaultDetails_ = _vaultDetails[vault];
        require(!vaultDetails_.isLinked, AlreadyLinkedVault());

        IVaultManager manager = vault.manager();
        manager.addVault(poolId, scId, assetId, vault, asset, tokenId);

        assetInfo[poolId][scId][assetId].numVaults++;
        vaultDetails_.isLinked = true;

        if (tokenId == 0) {
            shareClass_.shareToken.updateVault(asset, address(vault));
        }

        emit LinkVault(poolId, scId, asset, tokenId, vault);
    }

    /// @inheritdoc ISpoke
    function unlinkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault) public auth {
        require(vault.poolId() == poolId, InvalidVault());
        require(vault.scId() == scId, InvalidVault());

        (address asset, uint256 tokenId) = idToAsset(assetId);
        ShareClassDetails storage shareClass_ = _shareClass(poolId, scId);
        VaultDetails storage vaultDetails_ = _vaultDetails[vault];
        require(vaultDetails_.isLinked, AlreadyUnlinkedVault());

        IVaultManager manager = vault.manager();
        manager.removeVault(poolId, scId, assetId, vault, asset, tokenId);

        assetInfo[poolId][scId][assetId].numVaults--;
        vaultDetails_.isLinked = false;

        if (tokenId == 0) {
            shareClass_.shareToken.updateVault(asset, address(0));
        }

        emit UnlinkVault(poolId, scId, asset, tokenId, vault);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function isPoolActive(PoolId poolId) public view returns (bool) {
        return pool[poolId].createdAt > 0;
    }

    /// @inheritdoc ISpoke
    function shareToken(PoolId poolId, ShareClassId scId) public view returns (IShareToken) {
        return _shareClass(poolId, scId).shareToken;
    }

    /// @inheritdoc ISpoke
    function idToAsset(AssetId assetId) public view returns (address asset, uint256 tokenId) {
        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        require(assetIdKey.asset != address(0), UnknownAsset());
        return (assetIdKey.asset, assetIdKey.tokenId);
    }

    /// @inheritdoc ISpoke
    function assetToId(address asset, uint256 tokenId) public view returns (AssetId assetId) {
        assetId = _assetToId[asset][tokenId];
        require(assetId.raw() != 0, UnknownAsset());
    }

    /// @inheritdoc ISpoke
    function pricePoolPerShare(PoolId poolId, ShareClassId scId, bool checkValidity) public view returns (D18 price) {
        ShareClassDetails storage shareClass_ = _shareClass(poolId, scId);
        require(!checkValidity || shareClass_.pricePoolPerShare.isValid(), InvalidPrice());

        return shareClass_.pricePoolPerShare.price;
    }

    /// @inheritdoc ISpoke
    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        public
        view
        returns (D18 price)
    {
        Price memory poolPerAsset = assetInfo[poolId][scId][assetId].pricePoolPerAsset;
        require(!checkValidity || poolPerAsset.isValid(), InvalidPrice());

        return poolPerAsset.price;
    }

    /// @inheritdoc ISpoke
    function pricesPoolPer(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        public
        view
        returns (D18 pricePoolPerAsset_, D18 pricePoolPerShare_)
    {
        ShareClassDetails storage shareClass_ = _shareClass(poolId, scId);

        Price memory poolPerAsset = assetInfo[poolId][scId][assetId].pricePoolPerAsset;
        Price memory poolPerShare = shareClass_.pricePoolPerShare;

        require(!checkValidity || poolPerAsset.isValid() && poolPerShare.isValid(), InvalidPrice());

        return (poolPerAsset.price, poolPerShare.price);
    }

    /// @inheritdoc ISpoke
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

    /// @inheritdoc ISpoke
    function markersPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil)
    {
        Price memory poolPerAsset = assetInfo[poolId][scId][assetId].pricePoolPerAsset;
        computedAt = poolPerAsset.computedAt;
        maxAge = poolPerAsset.maxAge;
        validUntil = poolPerAsset.validUntil();
    }

    /// @inheritdoc ISpoke
    function vaultDetails(IVault vault) public view returns (VaultDetails memory details) {
        details = _vaultDetails[vault];
        require(details.asset != address(0), UnknownVault());
    }

    /// @inheritdoc ISpoke
    function isLinked(IVault vault) public view returns (bool) {
        return _vaultDetails[vault].isLinked;
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    function _safeGetAssetDecimals(address asset, uint256 tokenId) private view returns (uint8) {
        bytes memory callData;

        if (tokenId == 0) {
            callData = abi.encodeWithSignature("decimals()");
        } else {
            callData = abi.encodeWithSignature("decimals(uint256)", tokenId);
        }

        (bool success, bytes memory data) = asset.staticcall(callData);
        require(success && data.length >= 32, AssetMissingDecimals());

        return abi.decode(data, (uint8));
    }

    function _shareClass(PoolId poolId, ShareClassId scId)
        internal
        view
        returns (ShareClassDetails storage shareClass_)
    {
        shareClass_ = shareClass[poolId][scId];
        require(address(shareClass_.shareToken) != address(0), ShareTokenDoesNotExist());
    }
}
