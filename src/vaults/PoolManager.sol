// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20Metadata, IERC20Wrapper} from "src/misc/interfaces/IERC20.sol";
import {IERC6909, IERC6909MetadataExt} from "src/misc/interfaces/IERC6909.sol";
import {Auth} from "src/misc/Auth.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {Recoverable} from "src/misc/Recoverable.sol";

import {VaultUpdateKind, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IPoolManagerGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {IVaultMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {newAssetId} from "src/common/types/AssetId.sol";

import {IVaultFactory} from "src/vaults/interfaces/factories/IVaultFactory.sol";
import {IBaseVault, IAsyncRedeemVault} from "src/vaults/interfaces/IERC7540.sol";
import {IVaultManager, VaultKind} from "src/vaults/interfaces/IVaultManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {ISyncRequests} from "src/vaults/interfaces/investments/ISyncRequests.sol";
import {IAsyncRequests} from "src/vaults/interfaces/investments/IAsyncRequests.sol";
import {ITokenFactory} from "src/vaults/interfaces/factories/ITokenFactory.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IHook} from "src/vaults/interfaces/token/IHook.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {
    AssetIdKey,
    Pool,
    ShareClassDetails,
    SharePrice,
    UndeployedShare,
    VaultDetails,
    IPoolManager
} from "src/vaults/interfaces/IPoolManager.sol";
import {IEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IERC165} from "src/vaults/interfaces/IERC7575.sol";

/// @title  Pool Manager
/// @notice This contract manages which pools & share classes exist,
///         as well as managing allowed pool currencies, and incoming and outgoing transfers.
contract PoolManager is Auth, Recoverable, IPoolManager, IUpdateContract, IPoolManagerGatewayHandler {
    using CastLib for *;
    using MessageLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;

    uint8 internal constant MIN_DECIMALS = 2;
    uint8 internal constant MAX_DECIMALS = 18;

    IEscrow public immutable escrow;

    IVaultMessageSender public sender;
    ITokenFactory public tokenFactory;
    address public balanceSheet;

    uint64 internal _assetCounter;

    mapping(uint64 poolId => Pool) public pools;
    mapping(address factory => bool) public vaultFactory;
    mapping(address => VaultDetails) internal _vaultDetails;
    mapping(uint128 assetId => AssetIdKey) internal _idToAsset;
    /// @inheritdoc IPoolManager
    mapping(address asset => mapping(uint256 tokenId => uint128 assetId)) public assetToId;

    constructor(address escrow_, address tokenFactory_, address[] memory vaultFactories) Auth(msg.sender) {
        escrow = IEscrow(escrow_);
        tokenFactory = ITokenFactory(tokenFactory_);

        for (uint256 i = 0; i < vaultFactories.length; i++) {
            address factory = vaultFactories[i];
            vaultFactory[factory] = true;
        }
    }

    // --- Administration ---
    /// @inheritdoc IPoolManager
    function file(bytes32 what, address data) external auth {
        if (what == "sender") sender = IVaultMessageSender(data);
        else if (what == "tokenFactory") tokenFactory = ITokenFactory(data);
        else if (what == "balanceSheet") balanceSheet = data;
        else revert("PoolManager/file-unrecognized-param");
        emit File(what, data);
    }

    function file(bytes32 what, address factory, bool status) external auth {
        if (what == "vaultFactory") {
            vaultFactory[factory] = status;
        } else {
            revert("PoolManager/file-unrecognized-param");
        }
        emit File(what, factory, status);
    }

    // --- Outgoing message handling ---
    /// @inheritdoc IPoolManager
    function transferShares(uint16 centrifugeId, uint64 poolId, bytes16 scId, bytes32 receiver, uint128 amount)
        external
        auth
    {
        IShareToken shareToken_ = IShareToken(shareToken(poolId, scId));
        require(address(shareToken_) != address(0), "PoolManager/unknown-token");
        shareToken_.burn(msg.sender, amount);

        sender.sendTransferShares(centrifugeId, poolId, scId, receiver, amount);

        emit TransferShares(centrifugeId, poolId, scId, msg.sender, receiver, amount);
    }

    // @inheritdoc IPoolManagerGatewayHandler
    function registerAsset(uint16 centrifugeId, address asset, uint256 tokenId)
        external
        auth
        returns (uint128 assetId)
    {
        string memory name;
        string memory symbol;
        uint8 decimals;

        decimals = _safeGetAssetDecimals(asset, tokenId);
        require(decimals >= MIN_DECIMALS, "PoolManager/too-few-asset-decimals");
        require(decimals <= MAX_DECIMALS, "PoolManager/too-many-asset-decimals");

        if (tokenId == 0) {
            IERC20Metadata meta = IERC20Metadata(asset);
            name = meta.name();
            symbol = meta.symbol();
        } else {
            IERC6909MetadataExt meta = IERC6909MetadataExt(asset);
            name = meta.name(tokenId);
            symbol = meta.symbol(tokenId);
        }

        assetId = assetToId[asset][tokenId];
        if (assetId == 0) {
            _assetCounter++;
            assetId = newAssetId(sender.localCentrifugeId(), _assetCounter).raw();

            _idToAsset[assetId] = AssetIdKey(asset, tokenId);
            assetToId[asset][tokenId] = assetId;

            // Give pool manager infinite approval for asset
            // in the escrow to transfer to the user on transfer
            escrow.approveMax(asset, tokenId, address(this));

            // Give balance sheet manager infinite approval for asset
            // in the escrow to transfer to the user on transfer
            escrow.approveMax(asset, tokenId, balanceSheet);

            emit RegisterAsset(assetId, asset, tokenId, name, symbol, decimals);
        }

        sender.sendRegisterAsset(centrifugeId, assetId, decimals);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function addPool(uint64 poolId) public auth {
        Pool storage pool = pools[poolId];
        require(pool.createdAt == 0, "PoolManager/pool-already-added");
        pool.createdAt = block.timestamp;
        emit AddPool(poolId);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function addShareClass(
        uint64 poolId,
        bytes16 scId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        address hook
    ) public auth returns (address) {
        require(decimals >= MIN_DECIMALS, "PoolManager/too-few-token-decimals");
        require(decimals <= MAX_DECIMALS, "PoolManager/too-many-token-decimals");
        require(isPoolActive(poolId), "PoolManager/invalid-pool");
        require(shareToken(poolId, scId) == address(0), "PoolManager/share-class-already-exists");

        // Hook can be address zero if the share token is fully permissionless and has no custom logic
        require(hook == address(0) || _isValidHook(hook), "PoolManager/invalid-hook");

        address[] memory tokenWards = new address[](2);
        tokenWards[0] = address(this);
        // BalanceSheet needs this in order to mint shares
        tokenWards[1] = address(balanceSheet);

        address shareToken_ = tokenFactory.newToken(name, symbol, decimals, salt, tokenWards);

        if (hook != address(0)) {
            IShareToken(shareToken_).file("hook", hook);
        }

        pools[poolId].shareClasses[scId].shareToken = shareToken_;

        emit AddShareClass(poolId, scId, shareToken_);

        return shareToken_;
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function updateShareMetadata(uint64 poolId, bytes16 scId, string memory name, string memory symbol) public auth {
        IShareToken shareToken_ = IShareToken(shareToken(poolId, scId));
        require(address(shareToken_) != address(0), "PoolManager/unknown-token");

        require(
            keccak256(bytes(shareToken_.name())) != keccak256(bytes(name))
                || keccak256(bytes(shareToken_.symbol())) != keccak256(bytes(symbol)),
            "PoolManager/old-metadata"
        );

        shareToken_.file("name", name);
        shareToken_.file("symbol", symbol);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function updateSharePrice(uint64 poolId, bytes16 scId, uint128 assetId, uint128 price, uint64 computedAt)
        public
        auth
    {
        ShareClassDetails storage shareClass = pools[poolId].shareClasses[scId];
        require(shareClass.shareToken != address(0), "PoolManager/share-token-does-not-exist");

        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        require(
            computedAt >= shareClass.prices[assetIdKey.asset][assetIdKey.tokenId].computedAt,
            "PoolManager/cannot-set-older-price"
        );

        shareClass.prices[assetIdKey.asset][assetIdKey.tokenId] = SharePrice(price, computedAt);
        emit PriceUpdate(poolId, scId, assetIdKey.asset, assetIdKey.tokenId, price, computedAt);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function updateRestriction(uint64 poolId, bytes16 scId, bytes memory update_) public auth {
        IShareToken shareToken_ = IShareToken(shareToken(poolId, scId));
        require(address(shareToken_) != address(0), "PoolManager/unknown-token");
        address hook = shareToken_.hook();
        require(hook != address(0), "PoolManager/invalid-hook");
        IHook(hook).updateRestriction(address(shareToken_), update_);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function updateContract(uint64 poolId, bytes16 scId, address target, bytes memory update_) public auth {
        if (target == address(this)) {
            update(poolId, scId, update_);
        } else {
            IUpdateContract(target).update(poolId, scId, update_);
        }

        emit UpdateContract(poolId, scId, target, update_);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function updateShareHook(uint64 poolId, bytes16 scId, address hook) public auth {
        IShareToken shareToken_ = IShareToken(shareToken(poolId, scId));
        require(address(shareToken_) != address(0), "PoolManager/unknown-token");
        require(hook != shareToken_.hook(), "PoolManager/old-hook");
        shareToken_.file("hook", hook);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function handleTransferShares(uint64 poolId, bytes16 scId, address destinationAddress, uint128 amount)
        public
        auth
    {
        IShareToken shareToken_ = IShareToken(shareToken(poolId, scId));
        require(address(shareToken_) != address(0), "PoolManager/unknown-token");

        shareToken_.mint(destinationAddress, amount);
    }

    // --- IUpdateContract implementation ---
    /// @inheritdoc IUpdateContract
    /// @notice The pool manager either deploys the vault if a factory address is provided or it simply links/unlinks
    /// the vault
    function update(uint64 poolId, bytes16 scId, bytes memory payload) public auth {
        MessageLib.UpdateContractVaultUpdate memory m = MessageLib.deserializeUpdateContractVaultUpdate(payload);

        if (m.kind == uint8(VaultUpdateKind.DeployAndLink)) {
            address factory = address(bytes20(m.vaultOrFactory));

            address vault = deployVault(poolId, scId, m.assetId, factory);
            linkVault(poolId, scId, m.assetId, vault);
        } else {
            address vault = address(bytes20(m.vaultOrFactory));

            // Needed as safeguard against non-validated vaults
            // I.e. we only accept vaults that have been deployed by the pool manager
            require(_vaultDetails[vault].asset != address(0), "PoolManager/unknown-vault");

            if (m.kind == uint8(VaultUpdateKind.Link)) {
                linkVault(poolId, scId, m.assetId, vault);
            } else if (m.kind == uint8(VaultUpdateKind.Unlink)) {
                unlinkVault(poolId, scId, m.assetId, vault);
            } else {
                revert("PoolManager/malformed-vault-update-msg");
            }
        }
    }

    // --- Public functions ---
    /// @inheritdoc IPoolManager
    function deployVault(uint64 poolId, bytes16 scId, uint128 assetId, address factory) public auth returns (address) {
        ShareClassDetails storage shareClass = pools[poolId].shareClasses[scId];
        require(shareClass.shareToken != address(0), "PoolManager/share-token-does-not-exist");
        require(vaultFactory[factory], "PoolManager/invalid-factory");

        // Rely investment manager on vault so it can mint tokens
        address[] memory vaultWards = new address[](0);

        // Deploy vault
        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        address vault = IVaultFactory(factory).newVault(
            poolId, scId, assetIdKey.asset, assetIdKey.tokenId, shareClass.shareToken, address(escrow), vaultWards
        );

        // Check whether asset is an ERC20 token wrapper
        (bool success, bytes memory data) =
            assetIdKey.asset.staticcall(abi.encodeWithSelector(IERC20Wrapper.underlying.selector));
        // On success, the returned 20 byte address is padded to 32 bytes
        bool isWrappedERC20 = success && data.length == 32;
        _vaultDetails[vault] = VaultDetails(assetId, assetIdKey.asset, assetIdKey.tokenId, isWrappedERC20, false);

        // NOTE - Reverting the three actions below is not easy. We SHOULD do that if we phase-out a manager
        _approveManagers(vault, shareClass.shareToken, assetIdKey.asset, assetIdKey.tokenId);

        emit DeployVault(poolId, scId, assetIdKey.asset, assetIdKey.tokenId, factory, vault);
        return vault;
    }

    /// @inheritdoc IPoolManager
    function linkVault(uint64 poolId, bytes16 scId, uint128 assetId, address vault) public auth {
        ShareClassDetails storage shareClass = pools[poolId].shareClasses[scId];
        require(shareClass.shareToken != address(0), "PoolManager/share-token-does-not-exist");

        AssetIdKey memory assetIdKey = _idToAsset[assetId];

        IBaseInvestmentManager manager = IBaseVault(vault).manager();
        IVaultManager(address(manager)).addVault(poolId, scId, vault, assetIdKey.asset, assetId);

        _vaultDetails[vault].isLinked = true;

        emit LinkVault(poolId, scId, assetIdKey.asset, assetIdKey.tokenId, vault);
    }

    /// @inheritdoc IPoolManager
    function unlinkVault(uint64 poolId, bytes16 scId, uint128 assetId, address vault) public auth {
        ShareClassDetails storage shareClass = pools[poolId].shareClasses[scId];
        require(shareClass.shareToken != address(0), "PoolManager/share-token-does-not-exist");

        AssetIdKey memory assetIdKey = _idToAsset[assetId];

        IBaseInvestmentManager manager = IBaseVault(vault).manager();
        IVaultManager(address(manager)).removeVault(poolId, scId, vault, assetIdKey.asset, assetId);

        _vaultDetails[vault].isLinked = false;

        emit UnlinkVault(poolId, scId, assetIdKey.asset, assetIdKey.tokenId, vault);
    }

    // --- Helpers ---
    /// @inheritdoc IPoolManager
    function isPoolActive(uint64 poolId) public view returns (bool) {
        return pools[poolId].createdAt > 0;
    }

    /// @inheritdoc IPoolManager
    function shareToken(uint64 poolId, bytes16 scId) public view returns (address) {
        ShareClassDetails storage shareClass = pools[poolId].shareClasses[scId];
        return shareClass.shareToken;
    }

    /// @inheritdoc IPoolManager
    function checkedShareToken(uint64 poolId, bytes16 scId) public view returns (address) {
        address shareToken_ = shareToken(poolId, scId);
        require(shareToken_ != address(0), "PoolManager/unknown-token");
        return shareToken_;
    }

    /// @inheritdoc IPoolManager
    function sharePrice(uint64 poolId, bytes16 scId, uint128 assetId)
        public
        view
        returns (uint128 price, uint64 computedAt)
    {
        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        SharePrice memory value = pools[poolId].shareClasses[scId].prices[assetIdKey.asset][assetIdKey.tokenId];
        require(value.computedAt > 0, "PoolManager/unknown-price");
        price = value.price;
        computedAt = value.computedAt;
    }

    /// @inheritdoc IPoolManager
    function vaultDetails(address vault) public view returns (VaultDetails memory details) {
        details = _vaultDetails[vault];
        require(details.asset != address(0), "PoolManager/unknown-vault");
    }

    /// @inheritdoc IPoolManager
    function isLinked(uint64, /* poolId */ bytes16, /* scId */ address, /* asset */ address vault)
        public
        view
        returns (bool)
    {
        return _vaultDetails[vault].isLinked;
    }

    /// @inheritdoc IPoolManager
    function idToAsset(uint128 assetId) public view returns (address asset, uint256 tokenId) {
        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        return (assetIdKey.asset, assetIdKey.tokenId);
    }

    /// @inheritdoc IPoolManager
    function checkedIdToAsset(uint128 assetId) public view returns (address asset, uint256 tokenId) {
        (asset, tokenId) = idToAsset(assetId);
        require(asset != address(0), "PoolManager/unknown-asset");
    }

    /// @inheritdoc IPoolManager
    function checkedAssetToId(address asset, uint256 tokenId) public view returns (uint128 assetId) {
        assetId = assetToId[asset][tokenId];
        require(assetId != 0, "PoolManager/unknown-asset");
    }

    /// @dev Sets up permissions for the base vault manager and potentially a secondary manager (in case of partially
    /// sync vault)
    function _approveManagers(address vault, address shareToken_, address asset, uint256 tokenId) internal {
        address manager = address(IBaseVault(vault).manager());
        _approveManager(manager, shareToken_, asset, tokenId);

        // For sync deposit & async redeem vault, also repeat above for async manager (base manager is sync one)
        (VaultKind vaultKind, address secondaryVaultManager) = IVaultManager(manager).vaultKind(vault);
        if (vaultKind == VaultKind.SyncDepositAsyncRedeem) {
            _approveManager(secondaryVaultManager, shareToken_, asset, tokenId);
        }
    }

    /// @dev Sets up permissions for a vault manager
    function _approveManager(address manager, address shareToken_, address asset, uint256 tokenId) internal {
        IAuth(shareToken_).rely(manager);
        escrow.approveMax(shareToken_, manager);
        escrow.approveMax(asset, tokenId, manager);
    }

    function _safeGetAssetDecimals(address asset, uint256 tokenId) private view returns (uint8) {
        bytes memory callData;

        if (tokenId == 0) {
            callData = abi.encodeWithSignature("decimals()");
        } else {
            callData = abi.encodeWithSignature("decimals(uint256)", tokenId);
        }

        (bool success, bytes memory data) = asset.staticcall(callData);
        require(success && data.length >= 32, "PoolManager/asset-missing-decimals");

        return abi.decode(data, (uint8));
    }

    function _isValidHook(address hook) internal view returns (bool) {
        (bool success, bytes memory data) =
            hook.staticcall(abi.encodeWithSelector(IERC165.supportsInterface.selector, type(IHook).interfaceId));

        return success && data.length == 32 && abi.decode(data, (bool));
    }
}
