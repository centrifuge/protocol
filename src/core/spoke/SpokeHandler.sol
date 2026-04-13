// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IShareToken} from "./interfaces/IShareToken.sol";
import {ISpokeHandler} from "./interfaces/ISpokeHandler.sol";
import {ITransferHook} from "./interfaces/ITransferHook.sol";
import {ISpokeRegistry} from "./interfaces/ISpokeRegistry.sol";
import {ITokenFactory} from "./factories/interfaces/ITokenFactory.sol";
import {IPoolEscrowFactory} from "./factories/interfaces/IPoolEscrowFactory.sol";

import {Auth} from "../../misc/Auth.sol";
import {D18} from "../../misc/types/D18.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";

import {ISpokeGatewayHandler} from "../messaging/interfaces/IGatewayHandlers.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {IRequestManager} from "../interfaces/IRequestManager.sol";

/// @title  SpokeHandler
/// @notice This contract handles incoming cross-chain messages from the hub,
///         routing pool, share class, price, and restriction updates to the SpokeRegistry.
contract SpokeHandler is Auth, ISpokeHandler, ISpokeGatewayHandler {
    using CastLib for *;

    uint8 internal constant MIN_DECIMALS = 2;
    uint8 internal constant MAX_DECIMALS = 18;

    ISpokeRegistry public spokeRegistry;
    ITokenFactory public tokenFactory;
    IPoolEscrowFactory public poolEscrowFactory;

    constructor(
        ISpokeRegistry spokeRegistry_,
        ITokenFactory tokenFactory_,
        IPoolEscrowFactory poolEscrowFactory_,
        address deployer
    ) Auth(deployer) {
        spokeRegistry = spokeRegistry_;
        tokenFactory = tokenFactory_;
        poolEscrowFactory = poolEscrowFactory_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeHandler
    function file(bytes32 what, address data) external auth {
        if (what == "spokeRegistry") spokeRegistry = ISpokeRegistry(data);
        else if (what == "tokenFactory") tokenFactory = ITokenFactory(data);
        else if (what == "poolEscrowFactory") poolEscrowFactory = IPoolEscrowFactory(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Pool & token management (ISpokeGatewayHandler)
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
        address hook
    ) external auth {
        IShareToken shareToken_ = tokenFactory.newToken(name, symbol, decimals, salt);
        if (hook != address(0)) shareToken_.file("hook", hook);
        spokeRegistry.addShareClass(poolId, scId, shareToken_);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function setRequestManager(PoolId poolId, IRequestManager manager) external auth {
        spokeRegistry.setRequestManager(poolId, manager);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updateShareMetadata(PoolId poolId, ShareClassId scId, string memory name, string memory symbol)
        external
        auth
    {
        IShareToken shareToken_ = spokeRegistry.shareToken(poolId, scId);
        require(
            keccak256(bytes(shareToken_.name())) != keccak256(bytes(name))
                || keccak256(bytes(shareToken_.symbol())) != keccak256(bytes(symbol)),
            OldMetadata()
        );

        shareToken_.file("name", name);
        shareToken_.file("symbol", symbol);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updateShareHook(PoolId poolId, ShareClassId scId, address hook) external auth {
        IShareToken shareToken_ = spokeRegistry.shareToken(poolId, scId);
        require(hook != shareToken_.hook(), OldHook());
        shareToken_.file("hook", hook);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function updateRestriction(PoolId poolId, ShareClassId scId, bytes memory update) external auth {
        IShareToken shareToken_ = spokeRegistry.shareToken(poolId, scId);
        address hook = shareToken_.hook();
        require(hook != address(0), InvalidHook());
        ITransferHook(hook).updateRestriction(address(shareToken_), update);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function executeTransferShares(PoolId poolId, ShareClassId scId, bytes32 receiver, uint128 amount) external auth {
        IShareToken shareToken_ = spokeRegistry.shareToken(poolId, scId);
        shareToken_.mint(address(this), amount);
        shareToken_.transfer(receiver.toAddress(), amount);
        emit ExecuteTransferShares(poolId, scId, receiver.toAddress(), amount);
    }

    //----------------------------------------------------------------------------------------------
    // Price management (ISpokeGatewayHandler)
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

    /// @inheritdoc ISpokeGatewayHandler
    function setMaxSharePriceAge(PoolId poolId, ShareClassId scId, uint64 maxPriceAge) external auth {
        spokeRegistry.setMaxSharePriceAge(poolId, scId, maxPriceAge);
    }

    /// @inheritdoc ISpokeGatewayHandler
    function setMaxAssetPriceAge(PoolId poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge) external auth {
        spokeRegistry.setMaxAssetPriceAge(poolId, scId, assetId, maxPriceAge);
    }

    //----------------------------------------------------------------------------------------------
    // Request management (ISpokeGatewayHandler)
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeGatewayHandler
    function requestCallback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes memory payload) external auth {
        IRequestManager manager = spokeRegistry.requestManager(poolId);
        require(address(manager) != address(0), InvalidRequestManager());

        manager.callback(poolId, scId, assetId, payload);
    }
}
