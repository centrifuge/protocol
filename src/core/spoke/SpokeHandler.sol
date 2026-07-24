// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IVault} from "./interfaces/IVault.sol";
import {IRegistrar} from "./interfaces/IRegistrar.sol";
import {ISpokeHandler} from "./interfaces/ISpokeHandler.sol";
import {ISpokeRegistry} from "./interfaces/ISpokeRegistry.sol";
import {IVaultFactory} from "./factories/interfaces/IVaultFactory.sol";
import {ISpokeRequestManager} from "./interfaces/ISpokeRequestManager.sol";
import {IPoolEscrowFactory} from "./factories/interfaces/IPoolEscrowFactory.sol";

import {Auth} from "../../misc/Auth.sol";
import {D18} from "../../misc/types/D18.sol";
import {IERC20} from "../../misc/interfaces/IERC20.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {SafeTransferLib} from "../../misc/libraries/SafeTransferLib.sol";

import {VaultUpdateKind} from "../messaging/libraries/MessageLib.sol";
import {ISpokeGatewayHandler} from "../messaging/interfaces/IGatewayHandlers.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {IManifest} from "../hub/interfaces/IManifest.sol";

/// @title  SpokeHandler
/// @notice This contract handles incoming cross-chain messages from the hub,
///         routing pool, share class, price, and restriction updates to the SpokeRegistry.
contract SpokeHandler is Auth, ISpokeHandler, ISpokeGatewayHandler {
    using CastLib for *;

    ISpokeRegistry public spokeRegistry;
    IPoolEscrowFactory public poolEscrowFactory;

    constructor(ISpokeRegistry spokeRegistry_, IPoolEscrowFactory poolEscrowFactory_, address deployer) Auth(deployer) {
        spokeRegistry = spokeRegistry_;
        poolEscrowFactory = poolEscrowFactory_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeHandler
    function file(bytes32 what, address data) external auth {
        if (what == "spokeRegistry") spokeRegistry = ISpokeRegistry(data);
        else if (what == "poolEscrowFactory") poolEscrowFactory = IPoolEscrowFactory(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Pool & token management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeGatewayHandler
    function addPool(PoolId poolId) external auth {
        poolEscrowFactory.newEscrow(poolId);
        spokeRegistry.addPool(poolId);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function addShareClass(
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        IRegistrar registrar
    ) external auth {
        require(address(registrar) != address(0), InvalidRegistrar());

        address shareToken_ = registrar.newToken(name, symbol, decimals, salt);
        spokeRegistry.addShareClass(poolId, scId, shareToken_, registrar);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updateShareMetadata(PoolId poolId, ShareClassId scId, string memory name, string memory symbol)
        external
        auth
    {
        (IERC20 token, IRegistrar registrar) = spokeRegistry.shareTokenAndRegistrar(poolId, scId);
        registrar.updateMetadata(address(token), name, symbol);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updateRestriction(PoolId poolId, ShareClassId scId, bytes memory update) external auth {
        (IERC20 token, IRegistrar registrar) = spokeRegistry.shareTokenAndRegistrar(poolId, scId);
        registrar.updateRestriction(address(token), update);
    }

    /// @inheritdoc ISpokeGatewayHandler
    /// @dev The shares are minted to this contract and then transferred, so transfer hooks can
    ///      identify the flow as a crosschain transfer execution (this contract is the crosschain source).
    function executeTransferShares(PoolId poolId, ShareClassId scId, bytes32 receiver, uint128 amount) external auth {
        (IERC20 token, IRegistrar registrar) = spokeRegistry.shareTokenAndRegistrar(poolId, scId);
        registrar.mint(address(token), address(this), amount);
        SafeTransferLib.safeTransfer(address(token), receiver.toAddress(), amount);
        emit ExecuteTransferShares(poolId, scId, receiver.toAddress(), amount);
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
            (address asset, uint256 tokenId) = spokeRegistry.idToAsset(assetId);
            address shareToken = address(spokeRegistry.shareToken(poolId, scId));

            IVault vault_ = IVaultFactory(vaultOrFactory).newVault(poolId, scId, asset, tokenId, shareToken);

            spokeRegistry.registerVault(poolId, scId, assetId, asset, tokenId, IVaultFactory(vaultOrFactory), vault_);
            spokeRegistry.linkVault(poolId, scId, assetId, vault_);
        } else {
            IVault vault_ = IVault(vaultOrFactory);

            if (kind == VaultUpdateKind.Link) spokeRegistry.linkVault(poolId, scId, assetId, vault_);
            else if (kind == VaultUpdateKind.Unlink) spokeRegistry.unlinkVault(poolId, scId, assetId, vault_);
            else revert MalformedVaultUpdateMessage(); // Unreachable due to the enum check
        }
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updateManager(PoolId poolId, address who, bool canManage) external auth {
        spokeRegistry.updateManager(poolId, who, canManage);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updateBridger(PoolId poolId, address who, bool canBridge) external auth {
        spokeRegistry.updateBridger(poolId, who, canBridge);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function setManifest(PoolId poolId, IManifest manifest) external auth {
        spokeRegistry.setManifest(poolId, manifest);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function authorize(PoolId poolId, bytes calldata data) external auth {
        spokeRegistry.authorize(poolId, data);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function unauthorize(PoolId poolId, bytes calldata data) external auth {
        spokeRegistry.unauthorize(poolId, data);
    }

    //----------------------------------------------------------------------------------------------
    // Price management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeGatewayHandler
    function updatePricePoolPerShare(PoolId poolId, ShareClassId scId, D18 price, uint64 computedAt) external auth {
        spokeRegistry.updatePricePoolPerShare(poolId, scId, price, computedAt);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updatePricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, D18 price, uint64 computedAt)
        external
        auth
    {
        spokeRegistry.updatePricePoolPerAsset(poolId, scId, assetId, price, computedAt);
    }

    //----------------------------------------------------------------------------------------------
    // Request management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeGatewayHandler
    function setRequestManager(PoolId poolId, ISpokeRequestManager manager) external auth {
        spokeRegistry.setRequestManager(poolId, manager);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function requestCallback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes memory payload) external auth {
        ISpokeRequestManager manager = spokeRegistry.requestManager(poolId);
        require(address(manager) != address(0), InvalidRequestManager());

        manager.callback(poolId, scId, assetId, payload);
    }
}
