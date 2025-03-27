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

import {VaultUpdateKind, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IRecoverable} from "src/common/interfaces/IRoot.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IPoolManagerGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {IVaultMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {newAssetId} from "src/common/types/AssetId.sol";

import {IVaultFactory} from "src/vaults/interfaces/factories/IVaultFactory.sol";
import {IBaseVault, IAsyncRedeemVault} from "src/vaults/interfaces/IERC7540.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {ISyncInvestmentManager} from "src/vaults/interfaces/investments/ISyncInvestmentManager.sol";
import {IAsyncInvestmentManager} from "src/vaults/interfaces/investments/IAsyncInvestmentManager.sol";
import {ITrancheFactory} from "src/vaults/interfaces/factories/ITrancheFactory.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IHook} from "src/vaults/interfaces/token/IHook.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {
    AssetIdKey,
    Pool,
    TrancheDetails,
    TranchePrice,
    UndeployedTranche,
    VaultDetails,
    IPoolManager
} from "src/vaults/interfaces/IPoolManager.sol";
import {IEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IERC165} from "src/vaults/interfaces/IERC7575.sol";

/// @title  Pool Manager
/// @notice This contract manages which pools & tranches exist,
///         as well as managing allowed pool currencies, and incoming and outgoing transfers.
contract PoolManager is Auth, IPoolManager, IUpdateContract, IPoolManagerGatewayHandler {
    using MessageLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;
    using CastLib for *;

    uint8 internal constant MIN_DECIMALS = 2;
    uint8 internal constant MAX_DECIMALS = 18;

    IEscrow public immutable escrow;

    IVaultMessageSender public sender;
    ITrancheFactory public trancheFactory;
    address public balanceSheetManager;

    uint32 internal _assetCounter;

    mapping(uint64 poolId => Pool) public pools;
    mapping(address factory => bool) public vaultFactory;
    mapping(address => VaultDetails) internal _vaultDetails;
    mapping(uint128 assetId => AssetIdKey) internal _idToAsset;
    /// @inheritdoc IPoolManager
    mapping(address asset => mapping(uint256 tokenId => uint128 assetId)) public assetToId;

    constructor(address escrow_, address trancheFactory_, address[] memory vaultFactories) Auth(msg.sender) {
        escrow = IEscrow(escrow_);
        trancheFactory = ITrancheFactory(trancheFactory_);

        for (uint256 i = 0; i < vaultFactories.length; i++) {
            address factory = vaultFactories[i];
            vaultFactory[factory] = true;
        }
    }

    // --- Administration ---
    /// @inheritdoc IPoolManager
    function file(bytes32 what, address data) external auth {
        if (what == "sender") sender = IVaultMessageSender(data);
        else if (what == "trancheFactory") trancheFactory = ITrancheFactory(data);
        else if (what == "balanceSheetManager") balanceSheetManager = data;
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

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, uint256 tokenId, address to, uint256 amount) external auth {
        if (tokenId == 0) {
            SafeTransferLib.safeTransfer(token, to, amount);
        } else {
            IERC6909(token).transfer(to, tokenId, amount);
        }
    }

    // --- Outgoing message handling ---
    /// @inheritdoc IPoolManager
    function transferTrancheTokens(
        uint64 poolId,
        bytes16 trancheId,
        uint16 destinationId,
        bytes32 recipient,
        uint128 amount
    ) external auth {
        ITranche tranche_ = ITranche(tranche(poolId, trancheId));
        require(address(tranche_) != address(0), "PoolManager/unknown-token");
        tranche_.burn(msg.sender, amount);

        sender.sendTransferShares(destinationId, poolId, trancheId, recipient, amount);

        emit TransferTrancheTokens(poolId, trancheId, msg.sender, destinationId, recipient, amount);
    }

    // @inheritdoc IPoolManagerGatewayHandler
    function registerAsset(address asset, uint256 tokenId, uint16 destChainId)
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
            escrow.approveMax(asset, tokenId, balanceSheetManager);

            emit RegisterAsset(assetId, asset, tokenId, name, symbol, decimals);
        }

        sender.sendRegisterAsset(destChainId, assetId, name, symbol, decimals);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function addPool(uint64 poolId) public auth {
        Pool storage pool = pools[poolId];
        require(pool.createdAt == 0, "PoolManager/pool-already-added");
        pool.createdAt = block.timestamp;
        emit AddPool(poolId);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function addTranche(
        uint64 poolId,
        bytes16 trancheId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        address hook
    ) public auth returns (address) {
        require(decimals >= MIN_DECIMALS, "PoolManager/too-few-tranche-token-decimals");
        require(decimals <= MAX_DECIMALS, "PoolManager/too-many-tranche-token-decimals");
        require(isPoolActive(poolId), "PoolManager/invalid-pool");
        require(tranche(poolId, trancheId) == address(0), "PoolManager/tranche-already-exists");

        // Hook can be address zero if the tranche_token is fully permissionless and has no custom logic
        require(hook == address(0) || _isValidHook(hook), "PoolManager/invalid-hook");

        address[] memory trancheWards = new address[](2);
        trancheWards[0] = address(this);
        // BalanceSheetManager needs this in order to mint shares
        trancheWards[1] = address(balanceSheetManager);

        address token = trancheFactory.newTranche(name, symbol, decimals, salt, trancheWards);

        if (hook != address(0)) {
            ITranche(token).file("hook", hook);
        }

        pools[poolId].tranches[trancheId].token = token;

        emit AddTranche(poolId, trancheId, token);

        return token;
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function updateTrancheMetadata(uint64 poolId, bytes16 trancheId, string memory name, string memory symbol)
        public
        auth
    {
        ITranche tranche_ = ITranche(tranche(poolId, trancheId));
        require(address(tranche_) != address(0), "PoolManager/unknown-token");

        require(
            keccak256(bytes(tranche_.name())) != keccak256(bytes(name))
                || keccak256(bytes(tranche_.symbol())) != keccak256(bytes(symbol)),
            "PoolManager/old-metadata"
        );

        tranche_.file("name", name);
        tranche_.file("symbol", symbol);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function updateTranchePrice(uint64 poolId, bytes16 trancheId, uint128 assetId, uint128 price, uint64 computedAt)
        public
        auth
    {
        TrancheDetails storage tranche_ = pools[poolId].tranches[trancheId];
        require(tranche_.token != address(0), "PoolManager/tranche-does-not-exist");

        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        require(
            computedAt >= tranche_.prices[assetIdKey.asset][assetIdKey.tokenId].computedAt,
            "PoolManager/cannot-set-older-price"
        );

        tranche_.prices[assetIdKey.asset][assetIdKey.tokenId] = TranchePrice(price, computedAt);
        emit PriceUpdate(poolId, trancheId, assetIdKey.asset, assetIdKey.tokenId, price, computedAt);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function updateRestriction(uint64 poolId, bytes16 trancheId, bytes memory update_) public auth {
        ITranche tranche_ = ITranche(tranche(poolId, trancheId));
        require(address(tranche_) != address(0), "PoolManager/unknown-token");
        address hook = tranche_.hook();
        require(hook != address(0), "PoolManager/invalid-hook");
        IHook(hook).updateRestriction(address(tranche_), update_);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function updateContract(uint64 poolId, bytes16 trancheId, address target, bytes memory update_) public auth {
        if (target == address(this)) {
            update(poolId, trancheId, update_);
        } else {
            IUpdateContract(target).update(poolId, trancheId, update_);
        }

        emit UpdateContract(poolId, trancheId, target, update_);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function updateTrancheHook(uint64 poolId, bytes16 trancheId, address hook) public auth {
        ITranche tranche_ = ITranche(tranche(poolId, trancheId));
        require(address(tranche_) != address(0), "PoolManager/unknown-token");
        require(hook != tranche_.hook(), "PoolManager/old-hook");
        tranche_.file("hook", hook);
    }

    /// @inheritdoc IPoolManagerGatewayHandler
    function handleTransferTrancheTokens(uint64 poolId, bytes16 trancheId, address destinationAddress, uint128 amount)
        public
        auth
    {
        ITranche tranche_ = ITranche(tranche(poolId, trancheId));
        require(address(tranche_) != address(0), "PoolManager/unknown-token");

        tranche_.mint(destinationAddress, amount);
    }

    // --- IUpdateContract implementation ---
    /// @inheritdoc IUpdateContract
    /// @notice The pool manager either deploys the vault if a factory address is provided or it simply links/unlinks
    /// the vault
    function update(uint64 poolId, bytes16 trancheId, bytes memory payload) public auth {
        MessageLib.UpdateContractVaultUpdate memory m = MessageLib.deserializeUpdateContractVaultUpdate(payload);

        if (m.kind == uint8(VaultUpdateKind.DeployAndLink)) {
            address factory = address(bytes20(m.vaultOrFactory));

            address vault = deployVault(poolId, trancheId, m.assetId, factory);
            linkVault(poolId, trancheId, m.assetId, vault);
        } else {
            address vault = address(bytes20(m.vaultOrFactory));

            // Needed as safeguard against non-validated vaults
            // I.e. we only accept vaults that have been deployed by the pool manager
            require(_vaultDetails[vault].asset != address(0), "PoolManager/unknown-vault");

            if (m.kind == uint8(VaultUpdateKind.Link)) {
                linkVault(poolId, trancheId, m.assetId, vault);
            } else if (m.kind == uint8(VaultUpdateKind.Unlink)) {
                unlinkVault(poolId, trancheId, m.assetId, vault);
            } else {
                revert("PoolManager/malformed-vault-update-msg");
            }
        }
    }

    // --- Public functions ---
    /// @inheritdoc IPoolManager
    function deployVault(uint64 poolId, bytes16 trancheId, uint128 assetId, address factory)
        public
        auth
        returns (address)
    {
        TrancheDetails storage tranche_ = pools[poolId].tranches[trancheId];
        require(tranche_.token != address(0), "PoolManager/tranche-does-not-exist");
        require(vaultFactory[factory], "PoolManager/invalid-factory");

        // Rely investment manager on vault so it can mint tokens
        address[] memory vaultWards = new address[](0);

        // Deploy vault
        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        address vault = IVaultFactory(factory).newVault(
            poolId, trancheId, assetIdKey.asset, assetIdKey.tokenId, tranche_.token, address(escrow), vaultWards
        );

        // Check whether asset is an ERC20 token wrapper
        (bool success, bytes memory data) =
            assetIdKey.asset.staticcall(abi.encodeWithSelector(IERC20Wrapper.underlying.selector));
        // On success, the returned 20 byte address is padded to 32 bytes
        bool isWrappedERC20 = success && data.length == 32;
        _vaultDetails[vault] = VaultDetails(assetId, assetIdKey.asset, assetIdKey.tokenId, isWrappedERC20, false);

        address manager = address(IBaseVault(vault).manager());
        // NOTE - Reverting the three actions below is not easy. We SHOULD do that if we phase-out a manager
        IAuth(tranche_.token).rely(manager);
        escrow.approveMax(tranche_.token, manager);
        escrow.approveMax(assetIdKey.asset, assetIdKey.tokenId, manager);

        emit DeployVault(poolId, trancheId, assetIdKey.asset, assetIdKey.tokenId, factory, vault);
        return vault;
    }

    /// @inheritdoc IPoolManager
    function linkVault(uint64 poolId, bytes16 trancheId, uint128 assetId, address vault) public auth {
        TrancheDetails storage tranche_ = pools[poolId].tranches[trancheId];
        require(tranche_.token != address(0), "PoolManager/tranche-does-not-exist");

        AssetIdKey memory assetIdKey = _idToAsset[assetId];

        IBaseInvestmentManager manager = IBaseVault(vault).manager();
        IVaultManager(address(manager)).addVault(poolId, trancheId, vault, assetIdKey.asset, assetId);

        // For sync deposit & async redeem vault, also add vault to async manager (base manager is sync one)
        (bool isSyncDepositAsyncRedeemVault, address asyncRedeemManager) = isPartiallySyncVault(vault, manager);
        if (isSyncDepositAsyncRedeemVault) {
            IVaultManager(asyncRedeemManager).addVault(poolId, trancheId, vault, assetIdKey.asset, assetId);
        }

        _vaultDetails[vault].isLinked = true;

        emit LinkVault(poolId, trancheId, assetIdKey.asset, assetIdKey.tokenId, vault);
    }

    /// @inheritdoc IPoolManager
    function unlinkVault(uint64 poolId, bytes16 trancheId, uint128 assetId, address vault) public auth {
        TrancheDetails storage tranche_ = pools[poolId].tranches[trancheId];
        require(tranche_.token != address(0), "PoolManager/tranche-does-not-exist");

        AssetIdKey memory assetIdKey = _idToAsset[assetId];

        IBaseInvestmentManager manager = IBaseVault(vault).manager();
        IVaultManager(address(manager)).removeVault(poolId, trancheId, vault, assetIdKey.asset, assetId);

        // For sync deposit & async redeem vault, also add vault to async manager (base manager is sync one)
        (bool isSyncDepositAsyncRedeemVault, address asyncRedeemManager) = isPartiallySyncVault(vault, manager);
        if (isSyncDepositAsyncRedeemVault) {
            IVaultManager(asyncRedeemManager).removeVault(poolId, trancheId, vault, assetIdKey.asset, assetId);
        }

        _vaultDetails[vault].isLinked = false;

        emit UnlinkVault(poolId, trancheId, assetIdKey.asset, assetIdKey.tokenId, vault);
    }

    // --- Helpers ---
    /// @inheritdoc IPoolManager
    function isPoolActive(uint64 poolId) public view returns (bool) {
        return pools[poolId].createdAt > 0;
    }

    /// @inheritdoc IPoolManager
    function tranche(uint64 poolId, bytes16 trancheId) public view returns (address) {
        TrancheDetails storage tranche_ = pools[poolId].tranches[trancheId];
        return tranche_.token;
    }

    /// @inheritdoc IPoolManager
    function checkedTranche(uint64 poolId, bytes16 trancheId) public view returns (address) {
        address token = tranche(poolId, trancheId);
        require(token != address(0), "PoolManager/unknown-tranche");
        return token;
    }

    /// @inheritdoc IPoolManager
    function tranchePrice(uint64 poolId, bytes16 trancheId, uint128 assetId)
        public
        view
        returns (uint128 price, uint64 computedAt)
    {
        AssetIdKey memory assetIdKey = _idToAsset[assetId];
        TranchePrice memory value = pools[poolId].tranches[trancheId].prices[assetIdKey.asset][assetIdKey.tokenId];
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
    function isLinked(uint64, /* poolId */ bytes16, /* trancheId */ address, /* asset */ address vault)
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

    /// @inheritdoc IPoolManager
    function isPartiallySyncVault(address vault, IBaseInvestmentManager manager)
        public
        view
        returns (bool isPartial, address otherManager)
    {
        if (
            manager.supportsInterface(type(ISyncInvestmentManager).interfaceId)
                && IERC165(vault).supportsInterface(type(IAsyncRedeemVault).interfaceId)
        ) {
            isPartial = true;
            otherManager = address(IAsyncRedeemVault(vault).asyncManager());
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
        require(success && data.length >= 32, "PoolManager/asset-missing-decimals");

        return abi.decode(data, (uint8));
    }

    function _isValidHook(address hook) internal view returns (bool) {
        (bool success, bytes memory data) =
            hook.staticcall(abi.encodeWithSelector(IERC165.supportsInterface.selector, type(IHook).interfaceId));

        return success && data.length == 32 && abi.decode(data, (bool));
    }
}
