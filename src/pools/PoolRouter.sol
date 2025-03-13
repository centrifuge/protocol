// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {Auth} from "src/misc/Auth.sol";
import {Multicall} from "src/misc/Multicall.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId, newAccountId} from "src/common/types/AccountId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {IPoolRegistry} from "src/pools/interfaces/IPoolRegistry.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";
import {IPoolManager} from "src/pools/interfaces/IPoolManager.sol";
import {IPoolRouter} from "src/pools/interfaces/IPoolRouter.sol";

contract PoolRouter is Multicall, IPoolRouter {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @inheritdoc IPoolRouter
    function execute(PoolId poolId, bytes[] calldata data) external payable {
        poolManager.unlock(poolId, msg.sender);

        multicall(data);

        poolManager.lock();
    }

    /// @inheritdoc IPoolRouter
    function createPool(AssetId currency, IShareClassManager shareClassManager) external returns (PoolId poolId) {
        return poolManager.createPool(msg.sender, currency, shareClassManager);
    }

    /// @inheritdoc IPoolRouter
    function claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external protected {
        poolManager.claimDeposit(poolId, scId, assetId, investor);
    }

    /// @inheritdoc IPoolRouter
    function claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external protected {
        poolManager.claimRedeem(poolId, scId, assetId, investor);
    }

    /// @inheritdoc IPoolRouter
    function notifyPool(uint32 chainId) external protected {
        poolManager.notifyPool(chainId);
    }

    /// @inheritdoc IPoolRouter
    function notifyShareClass(uint32 chainId, ShareClassId scId, bytes32 hook) external protected {
        poolManager.notifyShareClass(chainId, scId, hook);
    }

    /// @inheritdoc IPoolRouter
    function setPoolMetadata(bytes calldata metadata) external protected {
        poolManager.setPoolMetadata(metadata);
    }

    /// @inheritdoc IPoolRouter
    function allowPoolAdmin(address account, bool allow) external protected {
        poolManager.allowPoolAdmin(account, allow);
    }

    /// @inheritdoc IPoolRouter
    function allowAsset(ShareClassId scId, AssetId assetId, bool allow) external protected {
        poolManager.allowAsset(scId, assetId, allow);
    }

    /// @inheritdoc IPoolRouter
    function addShareClass(string calldata name, string calldata symbol, bytes32 salt, bytes calldata data)
        external
        protected
    {
        poolManager.addShareClass(name, symbol, salt, data);
    }

    /// @inheritdoc IPoolRouter
    function approveDeposits(ShareClassId scId, AssetId paymentAssetId, uint128 maxApproval, IERC7726 valuation)
        external
        protected
    {
        poolManager.approveDeposits(scId, paymentAssetId, maxApproval, valuation);
    }

    /// @inheritdoc IPoolRouter
    function approveRedeems(ShareClassId scId, AssetId payoutAssetId, uint128 maxApproval) external protected {
        poolManager.approveRedeems(scId, payoutAssetId, maxApproval);
    }

    /// @inheritdoc IPoolRouter
    function issueShares(ShareClassId scId, AssetId depositAssetId, D18 navPerShare) external protected {
        poolManager.issueShares(scId, depositAssetId, navPerShare);
    }

    /// @inheritdoc IPoolRouter
    function revokeShares(ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation)
        external
        protected
    {
        poolManager.revokeShares(scId, payoutAssetId, navPerShare, valuation);
    }

    /// @inheritdoc IPoolRouter
    function createHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint24 prefix) external protected {
        poolManager.createHolding(scId, assetId, valuation, prefix);
    }

    /// @inheritdoc IPoolRouter
    function increaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount)
        external
        protected
    {
        poolManager.increaseHolding(scId, assetId, valuation, amount);
    }

    /// @inheritdoc IPoolRouter
    function decreaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount)
        external
        protected
    {
        poolManager.decreaseHolding(scId, assetId, valuation, amount);
    }

    /// @inheritdoc IPoolRouter
    function updateHolding(ShareClassId scId, AssetId assetId) external protected {
        poolManager.updateHolding(scId, assetId);
    }

    /// @inheritdoc IPoolRouter
    function updateHoldingValuation(ShareClassId scId, AssetId assetId, IERC7726 valuation) external protected {
        poolManager.updateHoldingValuation(scId, assetId, valuation);
    }

    /// @inheritdoc IPoolRouter
    function setHoldingAccountId(ShareClassId scId, AssetId assetId, AccountId accountId) external protected {
        poolManager.setHoldingAccountId(scId, assetId, accountId);
    }

    /// @inheritdoc IPoolRouter
    function createAccount(AccountId account, bool isDebitNormal) external protected {
        poolManager.createAccount(account, isDebitNormal);
    }

    /// @inheritdoc IPoolRouter
    function setAccountMetadata(AccountId account, bytes calldata metadata) external protected {
        poolManager.setAccountMetadata(account, metadata);
    }

    /// @inheritdoc IPoolRouter
    function addDebit(AccountId account, uint128 amount) external protected {
        poolManager.addDebit(account, amount);
    }

    /// @inheritdoc IPoolRouter
    function addCredit(AccountId account, uint128 amount) external protected {
        poolManager.addCredit(account, amount);
    }
}
