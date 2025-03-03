// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20Metadata, IERC20Wrapper} from "src/misc/interfaces/IERC20.sol";
import {Auth} from "src/misc/Auth.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";

import {ERC7540VaultFactory} from "src/vaults/factories/ERC7540VaultFactory.sol";
import {ITrancheFactory} from "src/vaults/interfaces/factories/ITrancheFactory.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IHook} from "src/vaults/interfaces/token/IHook.sol";
import {
    Pool,
    TrancheDetails,
    TranchePrice,
    UndeployedTranche,
    VaultAsset,
    IPoolManager
} from "src/vaults/interfaces/IPoolManager.sol";
import {IEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IGateway} from "src/vaults/interfaces/gateway/IGateway.sol";
import {IGasService} from "src/vaults/interfaces/gateway/IGasService.sol";
import {IRecoverable} from "src/vaults/interfaces/IRoot.sol";

/// @title  Pool Manager
/// @notice This contract manages which pools & tranches exist,
///         as well as managing allowed pool currencies, and incoming and outgoing transfers.
contract PoolManager is Auth, IPoolManager {
    using MessageLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;
    using CastLib for *;

    uint8 internal constant MIN_DECIMALS = 2;
    uint8 internal constant MAX_DECIMALS = 18;

    IEscrow public immutable escrow;

    IGateway public gateway;
    address public investmentManager;
    ERC7540VaultFactory public vaultFactory;
    ITrancheFactory public trancheFactory;
    IGasService public gasService;

    mapping(uint64 poolId => Pool) internal _pools;
    mapping(address => VaultAsset) internal _vaultToAsset;
    mapping(uint64 poolId => mapping(bytes16 => UndeployedTranche)) internal _undeployedTranches;

    /// @inheritdoc IPoolManager
    mapping(uint128 assetId => address) public idToAsset;
    /// @inheritdoc IPoolManager
    mapping(address => uint128 assetId) public assetToId;

    constructor(address escrow_, address vaultFactory_, address trancheFactory_) Auth(msg.sender) {
        escrow = IEscrow(escrow_);
        vaultFactory = ERC7540VaultFactory(vaultFactory_);
        trancheFactory = ITrancheFactory(trancheFactory_);
    }

    // --- Administration ---
    /// @inheritdoc IPoolManager
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "investmentManager") investmentManager = data;
        else if (what == "trancheFactory") trancheFactory = ITrancheFactory(data);
        else if (what == "vaultFactory") vaultFactory = ERC7540VaultFactory(data);
        else if (what == "gasService") gasService = IGasService(data);
        else revert("PoolManager/file-unrecognized-param");
        emit File(what, data);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, address to, uint256 amount) external auth {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    // --- Outgoing message handling ---
    /// @inheritdoc IPoolManager
    function transferTrancheTokens(
        uint64 poolId,
        bytes16 trancheId,
        uint32 destinationId,
        bytes32 recipient,
        uint128 amount
    ) external {
        ITranche tranche = ITranche(getTranche(poolId, trancheId));
        require(address(tranche) != address(0), "PoolManager/unknown-token");
        tranche.burn(msg.sender, amount);

        gateway.send(
            destinationId,
            MessageLib.TransferShares({poolId: poolId, scId: trancheId, recipient: recipient, amount: amount}).serialize(
            ),
            address(this)
        );

        emit TransferTrancheTokens(poolId, trancheId, msg.sender, destinationId, recipient, amount);
    }

    // --- Incoming message handling ---
    /// @inheritdoc IPoolManager
    function handle(bytes calldata message) external auth {
        MessageType kind = MessageLib.messageType(message);

        if (kind == MessageType.RegisterAsset) {
            // TODO: This must be removed
            addAsset(message.toUint128(1), message.toAddress(17));
        } else if (kind == MessageType.NotifyPool) {
            addPool(MessageLib.deserializeNotifyPool(message).poolId);
        } else if (kind == MessageType.NotifyShareClass) {
            MessageLib.NotifyShareClass memory m = MessageLib.deserializeNotifyShareClass(message);
            addTranche(m.poolId, m.scId, m.name, m.symbol.toString(), m.decimals, address(bytes20(m.hook)));
        } else if (kind == MessageType.AllowAsset) {
            MessageLib.AllowAsset memory m = MessageLib.deserializeAllowAsset(message);
            allowAsset(m.poolId, /* m.scId, */ m.assetId); // TODO: use scId
        } else if (kind == MessageType.DisallowAsset) {
            MessageLib.DisallowAsset memory m = MessageLib.deserializeDisallowAsset(message);
            disallowAsset(m.poolId, /* m.scId, */ m.assetId); // TODO: use scId
        } else if (kind == MessageType.UpdateShareClassPrice) {
            MessageLib.UpdateShareClassPrice memory m = MessageLib.deserializeUpdateShareClassPrice(message);
            updateTranchePrice(m.poolId, m.scId, m.assetId, m.price, m.timestamp);
        } else if (kind == MessageType.UpdateShareClassMetadata) {
            MessageLib.UpdateShareClassMetadata memory m = MessageLib.deserializeUpdateShareClassMetadata(message);
            updateTrancheMetadata(m.poolId, m.scId, m.name, m.symbol.toString());
        } else if (kind == MessageType.UpdateShareClassHook) {
            MessageLib.UpdateShareClassHook memory m = MessageLib.deserializeUpdateShareClassHook(message);
            updateTrancheHook(m.poolId, m.scId, address(bytes20(m.hook)));
        } else if (kind == MessageType.TransferShares) {
            MessageLib.TransferShares memory m = MessageLib.deserializeTransferShares(message);
            handleTransferTrancheTokens(m.poolId, m.scId, address(bytes20(m.recipient)), m.amount);
        } else if (kind == MessageType.UpdateRestriction) {
            MessageLib.UpdateRestriction memory m = MessageLib.deserializeUpdateRestriction(message);
            updateRestriction(m.poolId, m.scId, m.payload);
        } else {
            revert("PoolManager/invalid-message");
        }
    }

    /// @inheritdoc IPoolManager
    function addPool(uint64 poolId) public auth {
        Pool storage pool = _pools[poolId];
        require(pool.createdAt == 0, "PoolManager/pool-already-added");
        pool.createdAt = block.timestamp;
        emit AddPool(poolId);
    }

    /// @inheritdoc IPoolManager
    function allowAsset(uint64 poolId, uint128 assetId) public auth {
        require(isPoolActive(poolId), "PoolManager/invalid-pool");
        address asset = idToAsset[assetId];
        require(asset != address(0), "PoolManager/unknown-asset");

        _pools[poolId].allowedAssets[asset] = true;
        emit AllowAsset(poolId, asset);
    }

    /// @inheritdoc IPoolManager
    function disallowAsset(uint64 poolId, uint128 assetId) public auth {
        require(isPoolActive(poolId), "PoolManager/invalid-pool");
        address asset = idToAsset[assetId];
        require(asset != address(0), "PoolManager/unknown-asset");

        delete _pools[poolId].allowedAssets[asset];
        emit DisallowAsset(poolId, asset);
    }

    /// @inheritdoc IPoolManager
    function addTranche(
        uint64 poolId,
        bytes16 trancheId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        address hook
    ) public auth {
        require(decimals >= MIN_DECIMALS, "PoolManager/too-few-tranche-token-decimals");
        require(decimals <= MAX_DECIMALS, "PoolManager/too-many-tranche-token-decimals");
        require(isPoolActive(poolId), "PoolManager/invalid-pool");

        UndeployedTranche storage undeployedTranche = _undeployedTranches[poolId][trancheId];
        require(undeployedTranche.decimals == 0, "PoolManager/tranche-already-exists");
        require(getTranche(poolId, trancheId) == address(0), "PoolManager/tranche-already-deployed");

        // Hook can be address zero if the tranche token is fully permissionless and has no custom logic
        require(
            hook == address(0) || IHook(hook).supportsInterface(type(IHook).interfaceId) == true,
            "PoolManager/invalid-hook"
        );

        undeployedTranche.decimals = decimals;
        undeployedTranche.tokenName = name;
        undeployedTranche.tokenSymbol = symbol;
        undeployedTranche.hook = hook;

        emit AddTranche(poolId, trancheId);
    }

    /// @inheritdoc IPoolManager
    function updateTrancheMetadata(uint64 poolId, bytes16 trancheId, string memory name, string memory symbol)
        public
        auth
    {
        ITranche tranche = ITranche(getTranche(poolId, trancheId));
        require(address(tranche) != address(0), "PoolManager/unknown-token");

        require(
            keccak256(bytes(tranche.name())) != keccak256(bytes(name))
                || keccak256(bytes(tranche.symbol())) != keccak256(bytes(symbol)),
            "PoolManager/old-metadata"
        );

        tranche.file("name", name);
        tranche.file("symbol", symbol);
    }

    /// @inheritdoc IPoolManager
    function updateTranchePrice(uint64 poolId, bytes16 trancheId, uint128 assetId, uint128 price, uint64 computedAt)
        public
        auth
    {
        TrancheDetails storage tranche = _pools[poolId].tranches[trancheId];
        require(
            tranche.token != address(0) || canTrancheBeDeployed(poolId, trancheId), "PoolManager/tranche-does-not-exist"
        );

        address asset = idToAsset[assetId];
        require(computedAt >= tranche.prices[asset].computedAt, "PoolManager/cannot-set-older-price");

        tranche.prices[asset] = TranchePrice(price, computedAt);
        emit PriceUpdate(poolId, trancheId, asset, price, computedAt);
    }

    /// @inheritdoc IPoolManager
    function updateRestriction(uint64 poolId, bytes16 trancheId, bytes memory update) public auth {
        ITranche tranche = ITranche(getTranche(poolId, trancheId));
        require(address(tranche) != address(0), "PoolManager/unknown-token");
        address hook = tranche.hook();
        require(hook != address(0), "PoolManager/invalid-hook");
        IHook(hook).updateRestriction(address(tranche), update);
    }

    /// @inheritdoc IPoolManager
    function updateTrancheHook(uint64 poolId, bytes16 trancheId, address hook) public auth {
        ITranche tranche = ITranche(getTranche(poolId, trancheId));
        require(address(tranche) != address(0), "PoolManager/unknown-token");
        require(hook != tranche.hook(), "PoolManager/old-hook");
        tranche.file("hook", hook);
    }

    /// @inheritdoc IPoolManager
    function addAsset(uint128 assetId, address asset) public auth {
        // Currency index on the Centrifuge side should start at 1
        require(assetId != 0, "PoolManager/asset-id-has-to-be-greater-than-0");
        require(idToAsset[assetId] == address(0), "PoolManager/asset-id-in-use");
        require(assetToId[asset] == 0, "PoolManager/asset-address-in-use");

        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        require(assetDecimals >= MIN_DECIMALS, "PoolManager/too-few-asset-decimals");
        require(assetDecimals <= MAX_DECIMALS, "PoolManager/too-many-asset-decimals");

        idToAsset[assetId] = asset;
        assetToId[asset] = assetId;

        // Give investment manager infinite approval for asset
        // in the escrow to transfer to the user on redeem or withdraw
        escrow.approveMax(asset, investmentManager);

        // Give pool manager infinite approval for asset
        // in the escrow to transfer to the user on transfer
        escrow.approveMax(asset, address(this));

        emit AddAsset(assetId, asset);
    }

    /// @inheritdoc IPoolManager
    function handleTransferTrancheTokens(uint64 poolId, bytes16 trancheId, address destinationAddress, uint128 amount)
        public
        auth
    {
        ITranche tranche = ITranche(getTranche(poolId, trancheId));
        require(address(tranche) != address(0), "PoolManager/unknown-token");

        tranche.mint(destinationAddress, amount);
    }

    // --- Public functions ---
    // slither-disable-start reentrancy-eth
    /// @inheritdoc IPoolManager
    function deployTranche(uint64 poolId, bytes16 trancheId) external returns (address) {
        require(canTrancheBeDeployed(poolId, trancheId), "PoolManager/tranche-not-added");

        address[] memory trancheWards = new address[](2);
        trancheWards[0] = investmentManager;
        trancheWards[1] = address(this);

        UndeployedTranche storage undeployedTranche = _undeployedTranches[poolId][trancheId];
        address token = trancheFactory.newTranche(
            poolId,
            trancheId,
            undeployedTranche.tokenName,
            undeployedTranche.tokenSymbol,
            undeployedTranche.decimals,
            trancheWards
        );

        if (undeployedTranche.hook != address(0)) {
            ITranche(token).file("hook", undeployedTranche.hook);
        }

        _pools[poolId].tranches[trancheId].token = token;

        delete _undeployedTranches[poolId][trancheId];

        // Give investment manager infinite approval for tranche tokens
        // in the escrow to transfer to the user on deposit or mint
        escrow.approveMax(token, investmentManager);

        emit DeployTranche(poolId, trancheId, token);
        return token;
    }
    // slither-disable-end reentrancy-eth

    /// @inheritdoc IPoolManager
    function deployVault(uint64 poolId, bytes16 trancheId, address asset) external returns (address) {
        TrancheDetails storage tranche = _pools[poolId].tranches[trancheId];
        require(tranche.token != address(0), "PoolManager/tranche-does-not-exist");
        require(isAllowedAsset(poolId, asset), "PoolManager/asset-not-supported");

        address vault = ITranche(tranche.token).vault(asset);
        require(vault == address(0), "PoolManager/vault-already-deployed");

        // Rely investment manager on vault so it can mint tokens
        address[] memory vaultWards = new address[](1);
        vaultWards[0] = investmentManager;

        // Deploy vault
        vault = vaultFactory.newVault(
            poolId, trancheId, asset, tranche.token, address(escrow), investmentManager, vaultWards
        );

        // Check whether the ERC20 token is a wrapper
        try IERC20Wrapper(asset).underlying() returns (address) {
            _vaultToAsset[vault] = VaultAsset(asset, true);
        } catch {
            _vaultToAsset[vault] = VaultAsset(asset, false);
        }

        // Link vault to tranche token
        IAuth(tranche.token).rely(vault);
        ITranche(tranche.token).updateVault(asset, vault);

        emit DeployVault(poolId, trancheId, asset, vault);
        return vault;
    }

    /// @inheritdoc IPoolManager
    function removeVault(uint64 poolId, bytes16 trancheId, address asset) external auth {
        TrancheDetails storage tranche = _pools[poolId].tranches[trancheId];
        require(tranche.token != address(0), "PoolManager/tranche-does-not-exist");

        address vault = ITranche(tranche.token).vault(asset);
        require(vault != address(0), "PoolManager/vault-not-deployed");

        vaultFactory.denyVault(vault, investmentManager);

        delete _vaultToAsset[vault];

        IAuth(tranche.token).deny(vault);
        ITranche(tranche.token).updateVault(asset, address(0));

        emit RemoveVault(poolId, trancheId, asset, vault);
    }

    // --- Helpers ---
    /// @inheritdoc IPoolManager
    function isPoolActive(uint64 poolId) public view returns (bool) {
        return _pools[poolId].createdAt > 0;
    }

    /// @inheritdoc IPoolManager
    function getTranche(uint64 poolId, bytes16 trancheId) public view returns (address) {
        TrancheDetails storage tranche = _pools[poolId].tranches[trancheId];
        return tranche.token;
    }

    /// @inheritdoc IPoolManager
    function canTrancheBeDeployed(uint64 poolId, bytes16 trancheId) public view returns (bool) {
        return _undeployedTranches[poolId][trancheId].decimals > 0;
    }

    /// @inheritdoc IPoolManager
    function getTranchePrice(uint64 poolId, bytes16 trancheId, address asset)
        public
        view
        returns (uint128 price, uint64 computedAt)
    {
        TranchePrice memory value = _pools[poolId].tranches[trancheId].prices[asset];
        require(value.computedAt > 0, "PoolManager/unknown-price");
        price = value.price;
        computedAt = value.computedAt;
    }

    /// @inheritdoc IPoolManager
    function getVault(uint64 poolId, bytes16 trancheId, uint128 assetId) public view returns (address) {
        address vault = ITranche(_pools[poolId].tranches[trancheId].token).vault(idToAsset[assetId]);
        require(vault != address(0), "PoolManager/unknown-vault");
        return vault;
    }

    /// @inheritdoc IPoolManager
    function getVault(uint64 poolId, bytes16 trancheId, address asset) public view returns (address) {
        address vault = ITranche(_pools[poolId].tranches[trancheId].token).vault(asset);
        require(vault != address(0), "PoolManager/unknown-vault");
        return vault;
    }

    /// @inheritdoc IPoolManager
    function getVaultAsset(address vault) public view override returns (address, bool) {
        VaultAsset memory _asset = _vaultToAsset[vault];
        require(_asset.asset != address(0), "PoolManager/unknown-vault");
        return (_asset.asset, _asset.isWrapper);
    }

    /// @inheritdoc IPoolManager
    function isAllowedAsset(uint64 poolId, address asset) public view returns (bool) {
        return _pools[poolId].allowedAssets[asset];
    }
}
