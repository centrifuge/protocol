// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {Auth} from "src/misc/Auth.sol";
import {Multicall} from "src/misc/Multicall.sol";

import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {AccountId, newAccountId} from "src/pools/types/AccountId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {IAccounting} from "src/pools/interfaces/IAccounting.sol";
import {IGateway} from "src/pools/interfaces/IGateway.sol";
import {IPoolRegistry} from "src/pools/interfaces/IPoolRegistry.sol";
import {IAssetRegistry} from "src/pools/interfaces/IAssetRegistry.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";
import {ISingleShareClass} from "src/pools/interfaces/ISingleShareClass.sol";
import {IHoldings} from "src/pools/interfaces/IHoldings.sol";
import {
    IPoolManager,
    IPoolManagerHandler,
    EscrowId,
    AccountType
} from "src/pools/interfaces/IPoolManager.sol";
import {IPoolRouter} from "src/pools/interfaces/IPoolRouter.sol";

contract PoolRouter is Multicall, IPoolRouter {
    /// @dev Represents the unlocked pool Id in the multicall
    PoolId public transient unlockedPoolId;

    IPoolManager public poolManager;
    IPoolRegistry public poolRegistry;

    constructor(IPoolManager poolManager_, IPoolRegistry poolRegistry_) {
        poolManager = poolManager_;
        poolRegistry = poolRegistry_;
    }

    /// @dev A requirement for methods that needs to be called through `execute()`
    modifier poolUnlocked() {
        require(!unlockedPoolId.isNull(), IPoolRouter.PoolLocked());
        _;
    }

    /// @inheritdoc IPoolRouter
    function execute(PoolId poolId, bytes[] calldata data) external payable {
        require(unlockedPoolId.isNull(), IPoolRouter.PoolAlreadyUnlocked());
        require(poolRegistry.isAdmin(poolId, msg.sender), IPoolRouter.NotAuthorizedAdmin());

        poolManager.unlockAccounting(poolId);
        unlockedPoolId = poolId;

        multicall(data);

        poolManager.lockAccounting();
        unlockedPoolId = PoolId.wrap(0);
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
    function notifyPool(uint32 chainId) external poolUnlocked protected {
        poolManager.notifyPool(chainId, unlockedPoolId);
    }

    /// @inheritdoc IPoolRouter
    function notifyShareClass(uint32 chainId, ShareClassId scId, bytes32 hook) external poolUnlocked protected {
        poolManager.notifyShareClass(chainId, unlockedPoolId, scId, hook);
    }

    /// @inheritdoc IPoolRouter
    function setPoolMetadata(bytes calldata metadata) external poolUnlocked protected {
        poolManager.setPoolMetadata(unlockedPoolId, metadata);
    }

    /// @inheritdoc IPoolRouter
    function allowPoolAdmin(address account, bool allow) external poolUnlocked protected {
        poolManager.allowPoolAdmin(unlockedPoolId, account, allow);
    }

    /// @inheritdoc IPoolRouter
    function allowAsset(ShareClassId scId, AssetId assetId, bool allow) external poolUnlocked protected {
        poolManager.allowAsset(unlockedPoolId, scId, assetId, allow);
    }

    /// @inheritdoc IPoolRouter
    function addShareClass(string calldata name, string calldata symbol, bytes calldata data) external poolUnlocked protected {
        poolManager.addShareClass(unlockedPoolId, name, symbol, data);
    }

    /// @inheritdoc IPoolRouter
    function approveDeposits(ShareClassId scId, AssetId paymentAssetId, D18 approvalRatio, IERC7726 valuation)
        external
        poolUnlocked
        protected
    {
        poolManager.approveDeposits(unlockedPoolId, scId, paymentAssetId, approvalRatio, valuation);
    }

    /// @inheritdoc IPoolRouter
    function approveRedeems(ShareClassId scId, AssetId payoutAssetId, D18 approvalRatio)
        external
        poolUnlocked
        protected
    {
        poolManager.approveRedeems(unlockedPoolId, scId, payoutAssetId, approvalRatio);
    }

    /// @inheritdoc IPoolRouter
    function issueShares(ShareClassId scId, AssetId depositAssetId, D18 navPerShare) external poolUnlocked protected {
        poolManager.issueShares(unlockedPoolId, scId, depositAssetId, navPerShare);
    }

    /// @inheritdoc IPoolRouter
    function revokeShares(ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation)
        external
        poolUnlocked
        protected
    {
        poolManager.revokeShares(unlockedPoolId, scId, payoutAssetId, navPerShare, valuation);
    }

    /// @inheritdoc IPoolRouter
    function createHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint24 prefix)
        external
        poolUnlocked
        protected
    {
        poolManager.createHolding(unlockedPoolId, scId, assetId, valuation, prefix);
    }

    /// @inheritdoc IPoolRouter
    function increaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount)
        public
        poolUnlocked
        protected
    {
        poolManager.increaseHolding(unlockedPoolId, scId, assetId, valuation, amount);
    }

    /// @inheritdoc IPoolRouter
    function decreaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount)
        public
        poolUnlocked
        protected
    {
        poolManager.decreaseHolding(unlockedPoolId, scId, assetId, valuation, amount);
    }

    /// @inheritdoc IPoolRouter
    function updateHolding(ShareClassId scId, AssetId assetId) external poolUnlocked protected {
        poolManager.updateHolding(unlockedPoolId, scId, assetId);
    }

    /// @inheritdoc IPoolRouter
    function updateHoldingValuation(ShareClassId scId, AssetId assetId, IERC7726 valuation)
        external
        poolUnlocked
        protected
    {
        poolManager.updateHoldingValuation(unlockedPoolId, scId, assetId, valuation);
    }

    /// @inheritdoc IPoolRouter
    function setHoldingAccountId(ShareClassId scId, AssetId assetId, AccountId accountId)
        external
        poolUnlocked
        protected
    {
        poolManager.setHoldingAccountId(unlockedPoolId, scId, assetId, accountId);
    }

    /// @inheritdoc IPoolRouter
    function createAccount(AccountId account, bool isDebitNormal) public poolUnlocked protected {
        poolManager.createAccount(unlockedPoolId, account, isDebitNormal);
    }

    /// @inheritdoc IPoolRouter
    function setAccountMetadata(AccountId account, bytes calldata metadata) external poolUnlocked protected {
        poolManager.setAccountMetadata(unlockedPoolId, account, metadata);
    }

    /// @inheritdoc IPoolRouter
    function addDebit(AccountId account, uint128 amount) external poolUnlocked protected {
        poolManager.addDebit(account, amount);
    }

    /// @inheritdoc IPoolRouter
    function addCredit(AccountId account, uint128 amount) external poolUnlocked protected {
        poolManager.addCredit(account, amount);
    }
}
