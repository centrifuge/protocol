// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import {IERC6909MetadataExt} from "src/misc/interfaces/IERC6909.sol";
import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {D18} from "src/misc/types/D18.sol";
import {Recoverable} from "src/misc/Recoverable.sol";
import {IERC165} from "src/misc/interfaces/IERC7575.sol";
import {ReentrancyProtection} from "src/misc/ReentrancyProtection.sol";

import {VaultUpdateKind, MessageLib, UpdateContractType} from "src/common/libraries/MessageLib.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {ISpokeGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {IVaultMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {newAssetId, AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PricingLib} from "src/common/libraries/PricingLib.sol";

import {IVaultFactory} from "src/spoke/interfaces/factories/IVaultFactory.sol";
import {IBaseVault} from "src/spoke/interfaces/vaults/IBaseVaults.sol";
import {IBaseRequestManager} from "src/spoke/interfaces/investments/IBaseRequestManager.sol";
import {ITokenFactory} from "src/spoke/interfaces/factories/ITokenFactory.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IPoolEscrowFactory} from "src/spoke/interfaces/factories/IPoolEscrowFactory.sol";
import {IHook} from "src/common/interfaces/IHook.sol";
import {IUpdateContract} from "src/spoke/interfaces/IUpdateContract.sol";
import {AssetIdKey, Pool, ShareClassDetails, Price, VaultDetails, ISpoke} from "src/spoke/interfaces/ISpoke.sol";
import {IPoolEscrow} from "src/spoke/interfaces/IEscrow.sol";

/// @title  Spoke
/// @notice This contract manages which pools & share classes exist,
///         as well as managing allowed pool currencies, and incoming and outgoing transfers.
contract Spoke is Auth, Recoverable, ReentrancyProtection, ISpoke, IUpdateContract, ISpokeGatewayHandler {
    using CastLib for *;
    using MessageLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;

    uint8 internal constant MIN_DECIMALS = 2;
    uint8 internal constant MAX_DECIMALS = 18;

    IGateway public gateway;
    ITokenFactory public tokenFactory;
    IVaultMessageSender public sender;
    IPoolEscrowFactory public poolEscrowFactory;

    uint64 internal _assetCounter;

    mapping(PoolId poolId => Pool) public pools;
    mapping(IVaultFactory factory => bool) public vaultFactory;

    mapping(IBaseVault => VaultDetails) internal _vaultDetails;
    mapping(AssetId assetId => AssetIdKey) internal _idToAsset;
    mapping(address asset => mapping(uint256 tokenId => AssetId assetId)) internal _assetToId;

    constructor(ITokenFactory tokenFactory_, address deployer) Auth(deployer) {
        tokenFactory = tokenFactory_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function file(bytes32 what, address data) external auth {
        if (what == "sender") sender = IVaultMessageSender(data);
        else if (what == "tokenFactory") tokenFactory = ITokenFactory(data);
        else if (what == "gateway") gateway = IGateway(data);
        else if (what == "poolEscrowFactory") poolEscrowFactory = IPoolEscrowFactory(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc ISpoke
    function file(bytes32 what, address factory, bool status) external auth {
        if (what == "vaultFactory") vaultFactory[IVaultFactory(factory)] = status;
        else revert FileUnrecognizedParam();
        emit File(what, factory, status);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function transferShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bytes32 receiver, uint128 amount)
        external
        payable
        protected
    {
        IShareToken share = IShareToken(shareToken(poolId, scId));
        require(centrifugeId != sender.localCentrifugeId(), LocalTransferNotAllowed());
        require(
            share.checkTransferRestriction(msg.sender, address(uint160(centrifugeId)), amount),
            CrossChainTransferNotAllowed()
        );

        gateway.startTransactionPayment{value: msg.value}(msg.sender);

        share.authTransferFrom(msg.sender, msg.sender, address(this), amount);
        share.burn(address(this), amount);

        emit TransferShares(centrifugeId, poolId, scId, msg.sender, receiver, amount);
        sender.sendInitiateTransferShares(poolId, scId, centrifugeId, receiver, amount);

        gateway.endTransactionPayment();
    }

    /// @inheritdoc ISpoke
    function registerAsset(uint16 centrifugeId, address asset, uint256 tokenId)
        external
        payable
        protected
        returns (AssetId assetId)
    {
        string memory name;
        string memory symbol;
        uint8 decimals;

        decimals = _safeGetAssetDecimals(asset, tokenId);
        require(decimals >= MIN_DECIMALS, TooFewDecimals());
        require(decimals <= MAX_DECIMALS, TooManyDecimals());

        gateway.startTransactionPayment{value: msg.value}(msg.sender);

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
        if (assetId.raw() == 0) {
            _assetCounter++;
            assetId = newAssetId(sender.localCentrifugeId(), _assetCounter);

            _idToAsset[assetId] = AssetIdKey(asset, tokenId);
            _assetToId[asset][tokenId] = assetId;

            emit RegisterAsset(assetId, asset, tokenId, name, symbol, decimals);
        }

        sender.sendRegisterAsset(centrifugeId, assetId, decimals);

        gateway.endTransactionPayment();
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeGatewayHandler
    function addPool(PoolId poolId) public auth {
        Pool storage pool = pools[poolId];
        require(pool.createdAt == 0, PoolAlreadyAdded());
        pool.createdAt = block.timestamp;

        IPoolEscrow escrow = poolEscrowFactory.newEscrow(poolId);
        gateway.setRefundAddress(PoolId.wrap(poolId.raw()), escrow);

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
        require(decimals >= MIN_DECIMALS, TooFewDecimals());
        require(decimals <= MAX_DECIMALS, TooManyDecimals());
        require(isPoolActive(poolId), InvalidPool());

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
    function updatePricePoolPerShare(PoolId poolId, ShareClassId scId, uint128 price, uint64 computedAt) public auth {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);

        require(computedAt >= shareClass.pricePoolPerShare.computedAt, CannotSetOlderPrice());

        shareClass.pricePoolPerShare = Price(price, computedAt, shareClass.pricePoolPerShare.maxAge);
        emit PriceUpdate(poolId, scId, price, computedAt);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updatePricePoolPerAsset(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 poolPerAsset_,
        uint64 computedAt
    ) public auth {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);

        (address asset, uint256 tokenId) = idToAsset(assetId);
        Price storage poolPerAsset = shareClass.pricePoolPerAsset[asset][tokenId];
        require(computedAt >= poolPerAsset.computedAt, CannotSetOlderPrice());

        // Disable expiration of the price
        if (poolPerAsset.computedAt == 0) {
            poolPerAsset.maxAge = type(uint64).max;
        }
        poolPerAsset.price = poolPerAsset_;
        poolPerAsset.computedAt = computedAt;

        emit PriceUpdate(poolId, scId, asset, tokenId, poolPerAsset_, computedAt);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updateRestriction(PoolId poolId, ShareClassId scId, bytes memory update_) public auth {
        IShareToken shareToken_ = shareToken(poolId, scId);
        address hook = shareToken_.hook();
        require(hook != address(0), InvalidHook());
        IHook(hook).updateRestriction(address(shareToken_), update_);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updateContract(PoolId poolId, ShareClassId scId, address target, bytes memory update_) public auth {
        if (target == address(this)) {
            update(poolId, scId, update_);
        } else {
            IUpdateContract(target).update(poolId, scId, update_);
        }

        emit UpdateContract(poolId, scId, target, update_);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updateShareHook(PoolId poolId, ShareClassId scId, address hook) public auth {
        IShareToken shareToken_ = shareToken(poolId, scId);
        require(hook != shareToken_.hook(), OldHook());
        shareToken_.file("hook", hook);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function executeTransferShares(PoolId poolId, ShareClassId scId, bytes32 receiver, uint128 amount) public auth {
        IShareToken shareToken_ = shareToken(poolId, scId);
        shareToken_.mint(receiver.toAddress(), amount);
    }

    function updateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address vaultOrFactory,
        VaultUpdateKind kind
    ) external auth {
        if (kind == VaultUpdateKind.DeployAndLink) {
            IVaultFactory factory = IVaultFactory(vaultOrFactory);

            IBaseVault vault = deployVault(poolId, scId, assetId, factory);
            linkVault(poolId, scId, assetId, vault);
        } else {
            IBaseVault vault = IBaseVault(vaultOrFactory);

            // Needed as safeguard against non-validated vaults
            // I.e. we only accept vaults that have been deployed by the pool manager
            require(_vaultDetails[vault].asset != address(0), UnknownVault());

            if (kind == VaultUpdateKind.Link) {
                linkVault(poolId, scId, assetId, vault);
            } else if (kind == VaultUpdateKind.Unlink) {
                unlinkVault(poolId, scId, assetId, vault);
            } else {
                revert MalformedVaultUpdateMessage();
            }
        }
    }

    /// @inheritdoc IUpdateContract
    /// @notice The pool manager either deploys the vault if a factory address is provided
    ///         or it simply links/unlinks the vault.
    function update(PoolId poolId, ShareClassId scId, bytes memory payload) public auth {
        uint8 kind = uint8(MessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.MaxAssetPriceAge)) {
            MessageLib.UpdateContractMaxAssetPriceAge memory m =
                MessageLib.deserializeUpdateContractMaxAssetPriceAge(payload);

            ShareClassDetails storage shareClass = _shareClass(poolId, scId);
            require(m.assetId != 0, UnknownAsset());

            (address asset, uint256 tokenId) = idToAsset(AssetId.wrap(m.assetId));
            shareClass.pricePoolPerAsset[asset][tokenId].maxAge = m.maxPriceAge;
            emit UpdateMaxAssetPriceAge(poolId, scId, asset, tokenId, m.maxPriceAge);
        } else if (kind == uint8(UpdateContractType.MaxSharePriceAge)) {
            MessageLib.UpdateContractMaxSharePriceAge memory m =
                MessageLib.deserializeUpdateContractMaxSharePriceAge(payload);

            ShareClassDetails storage shareClass = _shareClass(poolId, scId);

            shareClass.pricePoolPerShare.maxAge = m.maxPriceAge;
            emit UpdateMaxSharePriceAge(poolId, scId, m.maxPriceAge);
        } else {
            revert UnknownUpdateContractType();
        }
    }

    /// @inheritdoc ISpoke
    function linkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IBaseVault vault) public auth {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);

        AssetIdKey memory assetIdKey = _idToAsset[assetId];

        IBaseRequestManager manager = vault.manager();
        manager.addVault(poolId, scId, vault, assetIdKey.asset, assetId);
        _vaultDetails[vault].isLinked = true;

        IAuth(address(shareClass.shareToken)).rely(address(vault));
        shareClass.shareToken.updateVault(vault.asset(), address(vault));

        emit LinkVault(poolId, scId, assetIdKey.asset, assetIdKey.tokenId, vault);
    }

    /// @inheritdoc ISpoke
    function unlinkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IBaseVault vault) public auth {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);

        AssetIdKey memory assetIdKey = _idToAsset[assetId];

        IBaseRequestManager manager = vault.manager();
        manager.removeVault(poolId, scId, vault, assetIdKey.asset, assetId);
        _vaultDetails[vault].isLinked = false;

        IAuth(address(shareClass.shareToken)).deny(address(vault));
        shareClass.shareToken.updateVault(vault.asset(), address(0));

        emit UnlinkVault(poolId, scId, assetIdKey.asset, assetIdKey.tokenId, vault);
    }

    /// @inheritdoc ISpoke
    function deployVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVaultFactory factory)
        public
        auth
        returns (IBaseVault)
    {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);
        require(vaultFactory[factory], InvalidFactory());

        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        IBaseVault vault = IVaultFactory(factory).newVault(
            poolId, scId, assetIdKey.asset, assetIdKey.tokenId, shareClass.shareToken, new address[](0)
        );

        registerVault(poolId, scId, assetId, assetIdKey.asset, assetIdKey.tokenId, factory, vault);
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
        IBaseVault vault
    ) public auth {
        _vaultDetails[vault] = VaultDetails(assetId, asset, tokenId, false);
        emit DeployVault(poolId, scId, asset, tokenId, factory, vault, vault.vaultKind());
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
        ShareClassDetails storage shareClass = pools[poolId].shareClasses[scId];
        require(address(shareClass.shareToken) != address(0), UnknownToken());
        return shareClass.shareToken;
    }

    /// @inheritdoc ISpoke
    function vaultDetails(IBaseVault vault) public view returns (VaultDetails memory details) {
        details = _vaultDetails[vault];
        require(details.asset != address(0), UnknownVault());
    }

    /// @inheritdoc ISpoke
    function isLinked(PoolId, /* poolId */ ShareClassId, /* scId */ address, /* asset */ IBaseVault vault)
        public
        view
        returns (bool)
    {
        return _vaultDetails[vault].isLinked;
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
    function priceAssetPerShare(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        public
        view
        returns (D18 price)
    {
        (Price memory poolPerAsset, Price memory poolPerShare) = _pricesPoolPer(poolId, scId, assetId, checkValidity);

        price = PricingLib.priceAssetPerShare(poolPerShare.asPrice(), poolPerAsset.asPrice());
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
            hook.staticcall(abi.encodeWithSelector(IERC165.supportsInterface.selector, type(IHook).interfaceId));

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
