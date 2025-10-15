// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Price} from "./types/Price.sol";
import {IShareToken} from "./interfaces/IShareToken.sol";
import {ITransferHook} from "./interfaces/ITransferHook.sol";
import {ITokenFactory} from "./factories/interfaces/ITokenFactory.sol";
import {IPoolEscrowFactory} from "./factories/interfaces/IPoolEscrowFactory.sol";
import {AssetIdKey, Pool, ShareClassDetails, ISpoke} from "./interfaces/ISpoke.sol";

import {Auth} from "../../misc/Auth.sol";
import {D18} from "../../misc/types/D18.sol";
import {Recoverable} from "../../misc/Recoverable.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {BytesLib} from "../../misc/libraries/BytesLib.sol";
import {IERC20Metadata} from "../../misc/interfaces/IERC20.sol";
import {IERC6909MetadataExt} from "../../misc/interfaces/IERC6909.sol";
import {ReentrancyProtection} from "../../misc/ReentrancyProtection.sol";

import {IGateway} from "../messaging/interfaces/IGateway.sol";
import {MessageLib} from "../messaging/libraries/MessageLib.sol";
import {ISpokeMessageSender} from "../messaging/interfaces/IGatewaySenders.sol";
import {ISpokeGatewayHandler} from "../messaging/interfaces/IGatewayHandlers.sol";

import {PoolId} from "../types/PoolId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {newAssetId, AssetId} from "../types/AssetId.sol";
import {IRequestManager} from "../interfaces/IRequestManager.sol";

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

    mapping(PoolId => Pool) public pool;
    mapping(PoolId => IRequestManager) public requestManager;
    mapping(PoolId => mapping(ShareClassId => ShareClassDetails)) public shareClass;

    uint64 internal _assetCounter;
    mapping(AssetId => AssetIdKey) internal _idToAsset;
    mapping(address asset => mapping(uint256 tokenId => AssetId)) internal _assetToId;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => Price))) internal _pricePoolPerAsset;

    constructor(ITokenFactory tokenFactory_, address deployer) Auth(deployer) {
        tokenFactory = tokenFactory_;
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
        uint128 extraGasLimit,
        uint128 remoteExtraGasLimit,
        address refund
    ) public payable protected {
        IShareToken share = IShareToken(shareToken(poolId, scId));
        require(centrifugeId != sender.localCentrifugeId(), LocalTransferNotAllowed());
        require(
            share.checkTransferRestriction(msg.sender, address(uint160(centrifugeId)), amount),
            CrossChainTransferNotAllowed()
        );

        share.authTransferFrom(msg.sender, msg.sender, address(this), amount);
        share.burn(address(this), amount);

        emit InitiateTransferShares(centrifugeId, poolId, scId, msg.sender, receiver, amount);

        sender.sendInitiateTransferShares{
            value: msg.value
        }(centrifugeId, poolId, scId, receiver, amount, extraGasLimit, remoteExtraGasLimit, refund);
    }

    /// @inheritdoc ISpoke
    function crosschainTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 remoteExtraGasLimit
    ) external payable protected {
        crosschainTransferShares(centrifugeId, poolId, scId, receiver, amount, 0, remoteExtraGasLimit, msg.sender);
    }

    /// @inheritdoc ISpoke
    function registerAsset(uint16 centrifugeId, address asset, uint256 tokenId, address refund)
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

        emit RegisterAsset(centrifugeId, assetId, asset, tokenId, name, symbol, decimals, isInitialization);
        sender.sendRegisterAsset{value: msg.value}(centrifugeId, assetId, decimals, refund);
    }

    /// @inheritdoc ISpoke
    function updateContract(
        PoolId poolId,
        ShareClassId scId,
        bytes32 target,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable {
        emit UntrustedContractUpdate(poolId.centrifugeId(), poolId, scId, target, payload, msg.sender);

        sender.sendUntrustedContractUpdate{
            value: msg.value
        }(poolId, scId, target, payload, msg.sender.toBytes32(), extraGasLimit, refund);
    }

    //----------------------------------------------------------------------------------------------
    // Pool & token management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeGatewayHandler
    function addPool(PoolId poolId) public auth {
        Pool storage pool_ = pool[poolId];
        require(pool_.createdAt == 0, PoolAlreadyAdded());
        pool_.createdAt = uint64(block.timestamp);
        poolEscrowFactory.newEscrow(poolId);

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
    function setRequestManager(PoolId poolId, IRequestManager manager) public auth {
        require(isPoolActive(poolId), InvalidPool());
        requestManager[poolId] = manager;
        emit SetRequestManager(poolId, manager);
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
        shareToken_.mint(address(this), amount);
        shareToken_.transfer(receiver.toAddress(), amount);
        emit ExecuteTransferShares(poolId, scId, receiver.toAddress(), amount);
    }

    /// @inheritdoc ISpoke
    function setShareTokenVault(PoolId poolId, ShareClassId scId, address asset, address vault) external auth {
        IShareToken token = shareToken(poolId, scId);
        token.updateVault(asset, vault);
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

    function setMaxSharePriceAge(PoolId poolId, ShareClassId scId, uint64 maxPriceAge) external auth {
        ShareClassDetails storage shareClass_ = _shareClass(poolId, scId);
        shareClass_.pricePoolPerShare.maxAge = maxPriceAge;
        emit UpdateMaxSharePriceAge(poolId, scId, maxPriceAge);
    }

    function setMaxAssetPriceAge(PoolId poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge) external auth {
        (address asset, uint256 tokenId) = idToAsset(assetId);
        _pricePoolPerAsset[poolId][scId][assetId].maxAge = maxPriceAge;
        emit UpdateMaxAssetPriceAge(poolId, scId, asset, tokenId, maxPriceAge);
    }

    //----------------------------------------------------------------------------------------------
    // Request management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function request(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes memory payload,
        address refund,
        bool unpaid
    ) external payable {
        IRequestManager manager = requestManager[poolId];
        require(address(manager) != address(0), InvalidRequestManager());
        require(msg.sender == address(manager), NotAuthorized());

        gateway.setUnpaidMode(unpaid);
        sender.sendRequest{value: msg.value}(poolId, scId, assetId, payload, refund);
        gateway.setUnpaidMode(false);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function requestCallback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes memory payload) external auth {
        IRequestManager manager = requestManager[poolId];
        require(address(manager) != address(0), InvalidRequestManager());

        manager.callback(poolId, scId, assetId, payload);
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
        Price memory poolPerAsset = _pricePoolPerAsset[poolId][scId][assetId];
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

        Price memory poolPerAsset = _pricePoolPerAsset[poolId][scId][assetId];
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
        Price memory poolPerAsset = _pricePoolPerAsset[poolId][scId][assetId];
        computedAt = poolPerAsset.computedAt;
        maxAge = poolPerAsset.maxAge;
        validUntil = poolPerAsset.validUntil();
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    function _safeGetAssetDecimals(address asset, uint256 tokenId) private view returns (uint8) {
        bytes memory callData;

        if (tokenId == 0) {
            callData = abi.encodeCall(IERC20Metadata.decimals, ());
        } else {
            callData = abi.encodeCall(IERC6909MetadataExt.decimals, tokenId);
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
