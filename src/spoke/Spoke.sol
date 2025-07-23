// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {D18} from "src/misc/types/D18.sol";
import {Recoverable} from "src/misc/Recoverable.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {IERC165} from "src/misc/interfaces/IERC7575.sol";
import {IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import {IERC6909MetadataExt} from "src/misc/interfaces/IERC6909.sol";
import {ReentrancyProtection} from "src/misc/ReentrancyProtection.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {newAssetId, AssetId} from "src/common/types/AssetId.sol";
import {IPoolEscrow} from "src/common/interfaces/IPoolEscrow.sol";
import {ITransferHook} from "src/common/interfaces/ITransferHook.sol";
import {ISpokeMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {ISpokeGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {VaultUpdateKind, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IPoolEscrowFactory} from "src/common/factories/interfaces/IPoolEscrowFactory.sol";

import {Price} from "src/spoke/types/Price.sol";
import {IVault} from "src/spoke/interfaces/IVault.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IVaultManager} from "src/spoke/interfaces/IVaultManager.sol";
import {IRequestManager} from "src/spoke/interfaces/IRequestManager.sol";
import {ITokenFactory} from "src/spoke/factories/interfaces/ITokenFactory.sol";
import {IVaultFactory} from "src/spoke/factories/interfaces/IVaultFactory.sol";
import {AssetIdKey, Pool, ShareClassDetails, VaultDetails, ISpoke} from "src/spoke/interfaces/ISpoke.sol";

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

    mapping(PoolId poolId => Pool) public pools;

    mapping(IVault => VaultDetails) internal _vaultDetails;
    mapping(AssetId assetId => AssetIdKey) internal _idToAsset;
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
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);
        require(msg.sender == address(shareClass.asset[assetId].manager), NotAuthorized());

        sender.sendRequest(poolId, scId, assetId, payload);
    }

    //----------------------------------------------------------------------------------------------
    // Pool & token management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeGatewayHandler
    function addPool(PoolId poolId) public auth {
        Pool storage pool = pools[poolId];
        require(pool.createdAt == 0, PoolAlreadyAdded());
        pool.createdAt = block.timestamp;

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
        require(address(pools[poolId].shareClasses[scId].shareToken) == address(0), ShareClassAlreadyRegistered());

        // Hook can be address zero if the share token is fully permissionless and has no custom logic
        require(hook == address(0) || _isValidHook(hook), InvalidHook());

        IShareToken shareToken_ = tokenFactory.newToken(name, symbol, decimals, salt);
        if (hook != address(0)) shareToken_.file("hook", hook);
        linkToken(poolId, scId, shareToken_);
    }

    /// @inheritdoc ISpoke
    function linkToken(PoolId poolId, ShareClassId scId, IShareToken shareToken_) public auth {
        pools[poolId].shareClasses[scId].shareToken = shareToken_;
        emit AddShareClass(poolId, scId, shareToken_);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function setRequestManager(PoolId poolId, ShareClassId scId, AssetId assetId, IRequestManager manager)
        public
        auth
    {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);
        require(shareClass.asset[assetId].numVaults == 0, MoreThanZeroLinkedVaults());
        shareClass.asset[assetId].manager = manager;
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
    function updatePricePoolPerShare(PoolId poolId, ShareClassId scId, uint128 price, uint64 computedAt) public auth {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);
        Price storage poolPerShare = shareClass.pricePoolPerShare;
        require(computedAt >= shareClass.pricePoolPerShare.computedAt, CannotSetOlderPrice());

        // Disable expiration of the price if never initialized
        if (poolPerShare.computedAt == 0 && poolPerShare.maxAge == 0) {
            poolPerShare.maxAge = type(uint64).max;
        }

        poolPerShare.price = price;
        poolPerShare.computedAt = computedAt;
        emit UpdateSharePrice(poolId, scId, price, computedAt);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updatePricePoolPerAsset(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 poolPerAsset_,
        uint64 computedAt
    ) public auth {
        (address asset, uint256 tokenId) = idToAsset(assetId);
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);
        Price storage poolPerAsset = shareClass.pricePoolPerAsset[asset][tokenId];
        require(computedAt >= poolPerAsset.computedAt, CannotSetOlderPrice());

        // Disable expiration of the price if never initialized
        if (poolPerAsset.computedAt == 0 && poolPerAsset.maxAge == 0) {
            poolPerAsset.maxAge = type(uint64).max;
        }

        poolPerAsset.price = poolPerAsset_;
        poolPerAsset.computedAt = computedAt;
        emit UpdateAssetPrice(poolId, scId, asset, tokenId, poolPerAsset_, computedAt);
    }

    function setMaxSharePriceAge(PoolId poolId, ShareClassId scId, uint64 maxPriceAge) external auth {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);
        shareClass.pricePoolPerShare.maxAge = maxPriceAge;
        emit UpdateMaxSharePriceAge(poolId, scId, maxPriceAge);
    }

    function setMaxAssetPriceAge(PoolId poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge) external auth {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);

        (address asset, uint256 tokenId) = idToAsset(assetId);
        shareClass.pricePoolPerAsset[asset][tokenId].maxAge = maxPriceAge;
        emit UpdateMaxAssetPriceAge(poolId, scId, asset, tokenId, maxPriceAge);
    }

    //----------------------------------------------------------------------------------------------
    // Vault management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeGatewayHandler
    function requestCallback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes memory payload) external auth {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);
        IRequestManager manager = shareClass.asset[assetId].manager;
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
            else revert MalformedVaultUpdateMessage();
        }
    }

    /// @inheritdoc ISpoke
    function deployVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVaultFactory factory)
        public
        auth
        returns (IVault)
    {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);
        (address asset, uint256 tokenId) = idToAsset(assetId);
        IVault vault = factory.newVault(poolId, scId, asset, tokenId, shareClass.shareToken, new address[](0));
        registerVault(poolId, scId, assetId, asset, tokenId, factory, vault);

        return vault;
    }

    /// @inheritdoc ISpoke
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
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);
        VaultDetails storage vaultDetails_ = _vaultDetails[vault];
        require(!vaultDetails_.isLinked, AlreadyLinkedVault());

        IVaultManager manager = vault.manager();
        manager.addVault(poolId, scId, assetId, vault, asset, tokenId);

        shareClass.asset[assetId].numVaults++;
        vaultDetails_.isLinked = true;

        if (tokenId == 0) {
            shareClass.shareToken.updateVault(asset, address(vault));
        }

        emit LinkVault(poolId, scId, asset, tokenId, vault);
    }

    /// @inheritdoc ISpoke
    function unlinkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault) public auth {
        require(vault.poolId() == poolId, InvalidVault());
        require(vault.scId() == scId, InvalidVault());

        (address asset, uint256 tokenId) = idToAsset(assetId);
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);
        VaultDetails storage vaultDetails_ = _vaultDetails[vault];
        require(vaultDetails_.isLinked, AlreadyLinkedVault());

        IVaultManager manager = vault.manager();
        manager.removeVault(poolId, scId, assetId, vault, asset, tokenId);

        shareClass.asset[assetId].numVaults--;
        vaultDetails_.isLinked = false;

        if (tokenId == 0) {
            shareClass.shareToken.updateVault(asset, address(0));
        }

        emit UnlinkVault(poolId, scId, asset, tokenId, vault);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function isPoolActive(PoolId poolId) public view returns (bool) {
        return pools[poolId].createdAt > 0;
    }

    /// @inheritdoc ISpoke
    function shareToken(PoolId poolId, ShareClassId scId) public view returns (IShareToken) {
        IShareToken token = pools[poolId].shareClasses[scId].shareToken;
        require(address(token) != address(0), UnknownToken());
        return token;
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
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);
        if (checkValidity) {
            require(shareClass.pricePoolPerShare.isValid(), InvalidPrice());
        }

        price = shareClass.pricePoolPerShare.asPrice();
    }

    /// @inheritdoc ISpoke
    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        public
        view
        returns (D18 price)
    {
        (Price memory poolPerAsset,) = _pricesPoolPer(poolId, scId, assetId, false);
        if (checkValidity) {
            require(poolPerAsset.isValid(), InvalidPrice());
        }

        price = poolPerAsset.asPrice();
    }

    /// @inheritdoc ISpoke
    function pricesPoolPer(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        public
        view
        returns (D18 pricePoolPerAsset_, D18 pricePoolPerShare_)
    {
        (Price memory poolPerAsset, Price memory poolPerShare) = _pricesPoolPer(poolId, scId, assetId, checkValidity);
        return (poolPerAsset.asPrice(), poolPerShare.asPrice());
    }

    /// @inheritdoc ISpoke
    function markersPricePoolPerShare(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil)
    {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);
        computedAt = shareClass.pricePoolPerShare.computedAt;
        maxAge = shareClass.pricePoolPerShare.maxAge;
        validUntil = shareClass.pricePoolPerShare.validUntil();
    }

    /// @inheritdoc ISpoke
    function markersPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil)
    {
        (Price memory poolPerAsset,) = _pricesPoolPer(poolId, scId, assetId, false);
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

    function _pricesPoolPer(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        internal
        view
        returns (Price memory poolPerAsset, Price memory poolPerShare)
    {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);

        (address asset, uint256 tokenId) = idToAsset(assetId);
        poolPerAsset = shareClass.pricePoolPerAsset[asset][tokenId];
        poolPerShare = shareClass.pricePoolPerShare;

        if (checkValidity) {
            require(poolPerAsset.isValid(), InvalidPrice());
            require(poolPerShare.isValid(), InvalidPrice());
        }
    }

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

    function _isValidHook(address hook) internal view returns (bool) {
        (bool success, bytes memory data) =
            hook.staticcall(abi.encodeWithSelector(IERC165.supportsInterface.selector, type(ITransferHook).interfaceId));

        return success && data.length == 32 && abi.decode(data, (bool));
    }

    function _shareClass(PoolId poolId, ShareClassId scId)
        internal
        view
        returns (ShareClassDetails storage shareClass)
    {
        shareClass = pools[poolId].shareClasses[scId];
        require(address(shareClass.shareToken) != address(0), ShareTokenDoesNotExist());
    }
}
