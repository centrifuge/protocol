// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {BeforeAfter} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";
// Chimera deps
import {vm} from "@chimera/Hevm.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";

import "src/pools/PoolManager.sol";

abstract contract PoolManagerTargets is
    BaseTargetFunctions,
    Properties
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///


    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function poolManager_addCredit(AccountId account, uint128 amount) public asActor {
        poolManager.addCredit(account, amount);
    }

    function poolManager_addDebit(AccountId account, uint128 amount) public asActor {
        poolManager.addDebit(account, amount);
    }

    function poolManager_addShareClass(string memory name, string memory symbol, bytes32 salt, bytes memory data) public asActor {
        poolManager.addShareClass(name, symbol, salt, data);
    }

    function poolManager_allowPoolAdmin(address account, bool allow) public asActor {
        poolManager.allowPoolAdmin(account, allow);
    }

    function poolManager_approveDeposits(ShareClassId scId, AssetId paymentAssetId, uint128 maxApproval, IERC7726 valuation) public asActor {
        poolManager.approveDeposits(scId, paymentAssetId, maxApproval, valuation);
    }

    function poolManager_approveRedeems(ShareClassId scId, AssetId payoutAssetId, uint128 maxApproval) public asActor {
        poolManager.approveRedeems(scId, payoutAssetId, maxApproval);
    }

    function poolManager_cancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId) public asActor {
        poolManager.cancelDepositRequest(poolId, scId, investor, depositAssetId);
    }

    function poolManager_cancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId) public asActor {
        poolManager.cancelRedeemRequest(poolId, scId, investor, payoutAssetId);
    }

    function poolManager_claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) public asActor {
        poolManager.claimDeposit(poolId, scId, assetId, investor);
    }

    function poolManager_claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) public asActor {
        poolManager.claimRedeem(poolId, scId, assetId, investor);
    }

    function poolManager_createAccount(AccountId account, bool isDebitNormal) public asActor {
        poolManager.createAccount(account, isDebitNormal);
    }

    function poolManager_createHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint24 prefix) public asActor {
        poolManager.createHolding(scId, assetId, valuation, prefix);
    }

    function poolManager_createPool(address admin, AssetId currency, IShareClassManager shareClassManager) public asActor {
        poolManager.createPool(admin, currency, shareClassManager);
    }

    function poolManager_decreaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount) public asActor {
        poolManager.decreaseHolding(scId, assetId, valuation, amount);
    }

    function poolManager_deny(address user) public asActor {
        poolManager.deny(user);
    }

    function poolManager_depositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId, uint128 amount) public asActor {
        poolManager.depositRequest(poolId, scId, investor, depositAssetId, amount);
    }

    function poolManager_file(bytes32 what, address data) public asActor {
        poolManager.file(what, data);
    }

    function poolManager_increaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount) public asActor {
        poolManager.increaseHolding(scId, assetId, valuation, amount);
    }

    function poolManager_issueShares(ShareClassId scId, AssetId depositAssetId, D18 navPerShare) public asActor {
        poolManager.issueShares(scId, depositAssetId, navPerShare);
    }

    function poolManager_lock() public asActor {
        poolManager.lock();
    }

    function poolManager_notifyPool(uint32 chainId) public asActor {
        poolManager.notifyPool(chainId);
    }

    function poolManager_notifyShareClass(uint32 chainId, ShareClassId scId, bytes32 hook) public asActor {
        poolManager.notifyShareClass(chainId, scId, hook);
    }

    function poolManager_redeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId, uint128 amount) public asActor {
        poolManager.redeemRequest(poolId, scId, investor, payoutAssetId, amount);
    }

    function poolManager_registerAsset(AssetId assetId, string memory name, string memory symbol, uint8 decimals) public asActor {
        poolManager.registerAsset(assetId, name, symbol, decimals);
    }

    function poolManager_rely(address user) public asActor {
        poolManager.rely(user);
    }

    function poolManager_revokeShares(ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation) public asActor {
        poolManager.revokeShares(scId, payoutAssetId, navPerShare, valuation);
    }

    function poolManager_setAccountMetadata(AccountId account, bytes memory metadata) public asActor {
        poolManager.setAccountMetadata(account, metadata);
    }

    function poolManager_setHoldingAccountId(ShareClassId scId, AssetId assetId, AccountId accountId) public asActor {
        poolManager.setHoldingAccountId(scId, assetId, accountId);
    }

    function poolManager_setPoolMetadata(bytes memory metadata) public asActor {
        poolManager.setPoolMetadata(metadata);
    }

    function poolManager_unlock(PoolId poolId, address admin) public asActor {
        poolManager.unlock(poolId, admin);
    }

    function poolManager_updateHolding(ShareClassId scId, AssetId assetId) public asActor {
        poolManager.updateHolding(scId, assetId);
    }

    function poolManager_updateHoldingValuation(ShareClassId scId, AssetId assetId, IERC7726 valuation) public asActor {
        poolManager.updateHoldingValuation(scId, assetId, valuation);
    }
}