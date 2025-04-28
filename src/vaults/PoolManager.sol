// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20Metadata, IERC20Wrapper} from "src/misc/interfaces/IERC20.sol";
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
import {IPoolManagerGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {IVaultMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {newAssetId, AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PricingLib} from "src/common/libraries/PricingLib.sol";

import {IVaultFactory} from "src/vaults/interfaces/factories/IVaultFactory.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";
import {IVaultManager, VaultKind} from "src/vaults/interfaces/IVaultManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {ITokenFactory} from "src/vaults/interfaces/factories/ITokenFactory.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IPoolEscrowFactory} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import {IHook} from "src/common/interfaces/IHook.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {
    AssetIdKey,
    Pool,
    ShareClassDetails,
    Price,
    VaultDetails,
    IPoolManager
} from "src/vaults/interfaces/IPoolManager.sol";
import {IPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";

/// @title  Pool Manager
/// @notice This contract manages which pools & share classes exist,
///         as well as managing allowed pool currencies, and incoming and outgoing transfers.
contract PoolManager is
    ReentrancyProtection,
    Auth,
    Recoverable,
    IPoolManager,
    IUpdateContract,
    IPoolManagerGatewayHandler
{
    using CastLib for *;
    using MessageLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;

    uint8 internal constant MIN_DECIMALS = 2;
    uint8 internal constant MAX_DECIMALS = 18;

    IGateway public gateway;
    address public balanceSheet;
    ITokenFactory public tokenFactory;
    IVaultMessageSender public sender;
    IPoolEscrowFactory public poolEscrowFactory;

    uint64 internal _assetCounter;

    mapping(PoolId poolId => Pool) public pools;
    mapping(IVaultFactory factory => bool) public vaultFactory;

    mapping(IBaseVault => VaultDetails) internal _vaultDetails;
    mapping(AssetId assetId => AssetIdKey) internal _idToAsset;
    mapping(address asset => mapping(uint256 tokenId => AssetId assetId)) internal _assetToId;

    constructor(ITokenFactory tokenFactory_, IVaultFactory[] memory vaultFactories, address deployer) Auth(deployer) {
        tokenFactory = tokenFactory_;

        for (uint256 i = 0; i < vaultFactories.length; i++) {
            IVaultFactory factory = vaultFactories[i];
            vaultFactory[factory] = true;
        }
    }

    //----------------------------------------------------------------------------------------------
    // Administration thods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManager
    function file(bytes32 what, address data) external auth {
        if (what == "sender") sender = IVaultMessageSender(data);
        else if (what == "tokenFactory") tokenFactory = ITokenFactory(data);
        else if (what == "gateway") gateway = IGateway(data);
        else if (what == "balanceSheet") balanceSheet = data;
        else if (what == "poolEscrowFactory") poolEscrowFactory = IPoolEscrowFactory(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    function file(bytes32 what, address factory, bool status) external auth {
        if (what == "vaultFactory") {
            vaultFactory[IVaultFactory(factory)] = status;
        } else {
            revert FileUnrecognizedParam();
        }
        emit File(what, factory, status);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManager
    function transferShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bytes32 receiver, uint128 amount)
        external
        payable
        protected
    {
        IShareToken share = IShareToken(shareToken(poolId, scId));
        require(
            share.checkTransferRestriction(msg.sender, address(uint160(centrifugeId)), amount),
            CrossChainTransferNotAllowed()
        );

        gateway.payTransaction{value: msg.value}(msg.sender);

        share.authTransferFrom(msg.sender, msg.sender, address(this), amount);
        share.burn(address(this), amount);

        emit TransferShares(centrifugeId, poolId, scId, msg.sender, receiver, amount);
        sender.sendTransferShares(centrifugeId, poolId, scId, receiver, amount);
    }

    // @inheritdoc IPoolManager
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

        gateway.payTransaction{value: msg.value}(msg.sender);

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
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManagerGatewayHandler
    function addPool(PoolId poolId) public auth {
        Pool storage pool = pools[poolId];
        require(pool.createdAt == 0, PoolAlreadyAdded());
        pool.createdAt = block.timestamp;

        IPoolEscrow escrow = poolEscrowFactory.newEscrow(poolId);
        gateway.setRefundAddress(PoolId.wrap(poolId.raw()), escrow);

        emit AddPool(poolId);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
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

        Pool storage pool = pools[poolId];
        require(address(pool.shareClasses[scId].shareToken) == address(0), ShareClassAlreadyRegistered());

        // Hook can be address zero if the share token is fully permissionless and has no custom logic
        require(hook == address(0) || _isValidHook(hook), InvalidHook());

        address[] memory tokenWards = new address[](2);
        tokenWards[0] = address(this);
        // BalanceSheet needs this in order to mint shares
        tokenWards[1] = balanceSheet;

        IShareToken shareToken_ = tokenFactory.newToken(name, symbol, decimals, salt, tokenWards);

        if (hook != address(0)) {
            shareToken_.file("hook", hook);
        }

        pool.shareClasses[scId].shareToken = shareToken_;

        emit AddShareClass(poolId, scId, shareToken_);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
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

    /// @inheritdoc IPoolManagerGatewayHandler
    function updatePricePoolPerShare(PoolId poolId, ShareClassId scId, uint128 price, uint64 computedAt) public auth {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);

        require(computedAt >= shareClass.pricePoolPerShare.computedAt, CannotSetOlderPrice());

        shareClass.pricePoolPerShare = Price(price, computedAt, shareClass.pricePoolPerShare.maxAge);
        emit PriceUpdate(poolId, scId, price, computedAt);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
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

        poolPerAsset.price = poolPerAsset_;
        poolPerAsset.computedAt = computedAt;

        emit PriceUpdate(poolId, scId, asset, tokenId, poolPerAsset_, computedAt);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function updateRestriction(PoolId poolId, ShareClassId scId, bytes memory update_) public auth {
        IShareToken shareToken_ = shareToken(poolId, scId);
        address hook = shareToken_.hook();
        require(hook != address(0), InvalidHook());
        IHook(hook).updateRestriction(address(shareToken_), update_);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function updateContract(PoolId poolId, ShareClassId scId, address target, bytes memory update_) public auth {
        if (target == address(this)) {
            update(poolId, scId, update_);
        } else {
            IUpdateContract(target).update(poolId, scId, update_);
        }

        emit UpdateContract(poolId, scId, target, update_);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function updateShareHook(PoolId poolId, ShareClassId scId, address hook) public auth {
        IShareToken shareToken_ = shareToken(poolId, scId);
        require(hook != shareToken_.hook(), OldHook());
        shareToken_.file("hook", hook);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function handleTransferShares(PoolId poolId, ShareClassId scId, address destinationAddress, uint128 amount)
        public
        auth
    {
        IShareToken shareToken_ = shareToken(poolId, scId);

        shareToken_.mint(destinationAddress, amount);
    }

    /// @inheritdoc IUpdateContract
    /// @notice The pool manager either deploys the vault if a factory address is provided or it simply links/unlinks
    /// the vault
    function update(PoolId poolId, ShareClassId scId, bytes memory payload) public auth {
        uint8 kind = uint8(MessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.VaultUpdate)) {
            MessageLib.UpdateContractVaultUpdate memory m = MessageLib.deserializeUpdateContractVaultUpdate(payload);

            if (m.kind == uint8(VaultUpdateKind.DeployAndLink)) {
                IVaultFactory factory = IVaultFactory(m.vaultOrFactory.toAddress());

                IBaseVault vault = deployVault(poolId, scId, AssetId.wrap(m.assetId), factory);
                linkVault(poolId, scId, AssetId.wrap(m.assetId), vault);
            } else {
                IBaseVault vault = IBaseVault(m.vaultOrFactory.toAddress());

                // Needed as safeguard against non-validated vaults
                // I.e. we only accept vaults that have been deployed by the pool manager
                require(_vaultDetails[vault].asset != address(0), UnknownVault());

                if (m.kind == uint8(VaultUpdateKind.Link)) {
                    linkVault(poolId, scId, AssetId.wrap(m.assetId), vault);
                } else if (m.kind == uint8(VaultUpdateKind.Unlink)) {
                    unlinkVault(poolId, scId, AssetId.wrap(m.assetId), vault);
                } else {
                    revert MalformedVaultUpdateMessage();
                }
            }
        } else if (kind == uint8(UpdateContractType.MaxAssetPriceAge)) {
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

    /// @inheritdoc IPoolManager
    function linkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IBaseVault vault) public auth {
        _shareClass(poolId, scId);

        AssetIdKey memory assetIdKey = _idToAsset[assetId];

        IBaseInvestmentManager manager = vault.manager();
        IVaultManager(address(manager)).addVault(poolId, scId, vault, assetIdKey.asset, assetId);

        _vaultDetails[vault].isLinked = true;

        emit LinkVault(poolId, scId, assetIdKey.asset, assetIdKey.tokenId, vault);
    }

    /// @inheritdoc IPoolManager
    function unlinkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IBaseVault vault) public auth {
        _shareClass(poolId, scId);

        AssetIdKey memory assetIdKey = _idToAsset[assetId];

        IBaseInvestmentManager manager = vault.manager();
        IVaultManager(address(manager)).removeVault(poolId, scId, vault, assetIdKey.asset, assetId);

        _vaultDetails[vault].isLinked = false;

        emit UnlinkVault(poolId, scId, assetIdKey.asset, assetIdKey.tokenId, vault);
    }

    /// @inheritdoc IPoolManager
    function deployVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVaultFactory factory)
        public
        auth
        returns (IBaseVault)
    {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);
        require(vaultFactory[factory], InvalidFactory());

        // Rely investment manager on vault so it can mint tokens
        address[] memory vaultWards = new address[](0);

        // Deploy vault
        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        IBaseVault vault = IVaultFactory(factory).newVault(
            poolId, scId, assetIdKey.asset, assetIdKey.tokenId, shareClass.shareToken, vaultWards
        );

        // Check whether asset is an ERC20 token wrapper
        (bool success, bytes memory data) =
            assetIdKey.asset.staticcall(abi.encodeWithSelector(IERC20Wrapper.underlying.selector));
        // On success, the returned 20 byte address is padded to 32 bytes
        bool isWrappedERC20 = success && data.length == 32;
        _vaultDetails[vault] = VaultDetails(assetId, assetIdKey.asset, assetIdKey.tokenId, isWrappedERC20, false);

        // NOTE - Reverting the manager approvals is not easy. We SHOULD do that if we phase-out a manager
        _relyShareToken(vault, shareClass.shareToken);

        emit DeployVault(poolId, scId, assetIdKey.asset, assetIdKey.tokenId, factory, vault);
        return vault;
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManager
    function isPoolActive(PoolId poolId) public view returns (bool) {
        return pools[poolId].createdAt > 0;
    }

    /// @inheritdoc IPoolManager
    function shareToken(PoolId poolId, ShareClassId scId) public view returns (IShareToken) {
        ShareClassDetails storage shareClass = pools[poolId].shareClasses[scId];
        require(address(shareClass.shareToken) != address(0), UnknownToken());
        return shareClass.shareToken;
    }

    /// @inheritdoc IPoolManager
    function vaultDetails(IBaseVault vault) public view returns (VaultDetails memory details) {
        details = _vaultDetails[vault];
        require(details.asset != address(0), UnknownVault());
    }

    /// @inheritdoc IPoolManager
    function isLinked(PoolId, /* poolId */ ShareClassId, /* scId */ address, /* asset */ IBaseVault vault)
        public
        view
        returns (bool)
    {
        return _vaultDetails[vault].isLinked;
    }

    /// @inheritdoc IPoolManager
    function idToAsset(AssetId assetId) public view returns (address asset, uint256 tokenId) {
        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        require(assetIdKey.asset != address(0), UnknownAsset());
        return (assetIdKey.asset, assetIdKey.tokenId);
    }

    /// @inheritdoc IPoolManager
    function assetToId(address asset, uint256 tokenId) public view returns (AssetId assetId) {
        assetId = _assetToId[asset][tokenId];
        require(assetId.raw() != 0, UnknownAsset());
    }

    /// @inheritdoc IPoolManager
    function priceAssetPerShare(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        public
        view
        returns (D18 price, uint64 computedAt)
    {
        (Price memory poolPerAsset, Price memory poolPerShare) = _pricesPoolPer(poolId, scId, assetId, checkValidity);

        price = PricingLib.priceAssetPerShare(poolPerShare.asPrice(), poolPerAsset.asPrice());
        computedAt = poolPerShare.computedAt;
    }

    /// @inheritdoc IPoolManager
    function pricePoolPerShare(PoolId poolId, ShareClassId scId, bool checkValidity)
        public
        view
        returns (D18 price, uint64 computedAt)
    {
        ShareClassDetails storage shareClass = _shareClass(poolId, scId);

        if (checkValidity) {
            require(shareClass.pricePoolPerShare.isValid(), InvalidPrice());
        }

        price = shareClass.pricePoolPerShare.asPrice();
        computedAt = shareClass.pricePoolPerShare.computedAt;
    }

    /// @inheritdoc IPoolManager
    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        public
        view
        returns (D18 price, uint64 computedAt)
    {
        (Price memory poolPerAsset,) = _pricesPoolPer(poolId, scId, assetId, false);

        if (checkValidity) {
            require(poolPerAsset.isValid(), InvalidPrice());
        }

        price = poolPerAsset.asPrice();
        computedAt = poolPerAsset.computedAt;
    }

    /// @inheritdoc IPoolManager
    function pricesPoolPer(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        public
        view
        returns (D18 pricePoolPerAsset_, D18 pricePoolPerShare_)
    {
        (Price memory poolPerAsset, Price memory poolPerShare) = _pricesPoolPer(poolId, scId, assetId, checkValidity);
        return (poolPerAsset.asPrice(), poolPerShare.asPrice());
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

    /// @dev Sets up approval permissions for pool, i.e. the pool escrow, the base vault manager and potentially a
    /// secondary manager (in case of partially sync vault)
    function _relyShareToken(IBaseVault vault, IShareToken shareToken_) internal {
        address manager = address(IBaseVault(vault).manager());
        IAuth(address(shareToken_)).rely(manager);

        // For sync deposit & async redeem vault, also repeat above for async manager (base manager is sync one)
        (VaultKind vaultKind, address secondaryVaultManager) = IVaultManager(manager).vaultKind(vault);
        if (vaultKind == VaultKind.SyncDepositAsyncRedeem) {
            IAuth(address(shareToken_)).rely(secondaryVaultManager);
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
