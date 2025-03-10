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

abstract contract AdminTargets is
    BaseTargetFunctions,
    Properties
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///


    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function poolManager_lock() public asAdmin {
        poolManager.lock();
    }

    function poolManager_unlock(PoolId poolId, address admin) public asAdmin {
        poolManager.unlock(poolId, admin);
    }

    function poolManager_createPool(address admin, AssetId currency, IShareClassManager shareClassManager) public asAdmin {
        poolManager.createPool(admin, currency, shareClassManager);
    }

    function poolManager_setAccountMetadata(AccountId account, bytes memory metadata) public asActor {
        poolManager.setAccountMetadata(account, metadata);
    }

    function poolManager_setHoldingAccountId(ShareClassId scId, AssetId assetId, AccountId accountId) public asActor {
        poolManager.setHoldingAccountId(scId, assetId, accountId);
    }

    function poolManager_setPoolMetadata(bytes memory metadata) public asAdmin {
        poolManager.setPoolMetadata(metadata);
    }

    function poolManager_notifyPool(uint32 chainId) public asAdmin {
        poolManager.notifyPool(chainId);
    }

    function poolManager_notifyShareClass(uint32 chainId, ShareClassId scId, bytes32 hook) public asAdmin {
        poolManager.notifyShareClass(chainId, scId, hook);
    }

    function poolManager_allowPoolAdmin(address account, bool allow) public asAdmin {
        poolManager.allowPoolAdmin(account, allow);
    }

    function poolManager_addShareClass(string memory name, string memory symbol, bytes32 salt, bytes memory data) public asAdmin {
        poolManager.addShareClass(name, symbol, salt, data);
    }

    function poolManager_approveDeposits(ShareClassId scId, AssetId paymentAssetId, uint128 maxApproval, IERC7726 valuation) public asAdmin {
        poolManager.approveDeposits(scId, paymentAssetId, maxApproval, valuation);
    }

    function poolManager_approveRedeems(ShareClassId scId, AssetId payoutAssetId, uint128 maxApproval) public asAdmin {
        poolManager.approveRedeems(scId, payoutAssetId, maxApproval);
    }   

    function poolManager_issueShares(ShareClassId scId, AssetId depositAssetId, D18 navPerShare) public asAdmin {
        poolManager.issueShares(scId, depositAssetId, navPerShare);
    }

    function poolManager_revokeShares(ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation) public asAdmin {
        poolManager.revokeShares(scId, payoutAssetId, navPerShare, valuation);
    }

    function poolManager_createHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint24 prefix) public asAdmin {
        poolManager.createHolding(scId, assetId, valuation, prefix);
    }

    function poolManager_decreaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount) public asAdmin {
        poolManager.decreaseHolding(scId, assetId, valuation, amount);
    }

    function poolManager_increaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount) public asAdmin {
        poolManager.increaseHolding(scId, assetId, valuation, amount);
    }

    function poolManager_updateHolding(ShareClassId scId, AssetId assetId) public asAdmin {
        poolManager.updateHolding(scId, assetId);
    }

    function poolManager_updateHoldingValuation(ShareClassId scId, AssetId assetId, IERC7726 valuation) public asAdmin {
        poolManager.updateHoldingValuation(scId, assetId, valuation);
    }

    function poolManager_createAccount(AccountId account, bool isDebitNormal) public asAdmin {
        poolManager.createAccount(account, isDebitNormal);
    }

    function poolManager_addCredit(AccountId account, uint128 amount) public asAdmin {
        poolManager.addCredit(account, amount);
    }

    function poolManager_addDebit(AccountId account, uint128 amount) public asAdmin {
        poolManager.addDebit(account, amount);
    }

    function poolManager_registerAsset(AssetId assetId, string memory name, string memory symbol, uint8 decimals) public asAdmin {
        poolManager.registerAsset(assetId, name, symbol, decimals);
    }  

    function poolManager_depositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId, uint128 amount) public asAdmin {
        poolManager.depositRequest(poolId, scId, investor, depositAssetId, amount);
    }  

    function poolManager_redeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId, uint128 amount) public asAdmin {
        poolManager.redeemRequest(poolId, scId, investor, payoutAssetId, amount);
    }  

    function poolManager_cancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId) public asAdmin {
        poolManager.cancelDepositRequest(poolId, scId, investor, depositAssetId);
    }

    function poolManager_cancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId) public asAdmin {
        poolManager.cancelRedeemRequest(poolId, scId, investor, payoutAssetId);
    }

    function poolManager_file(bytes32 what, address data) public asAdmin {
        poolManager.file(what, data);
    }

    // === SingleShareClass === //

    function singleShareClass_claimDepositUntilEpoch(PoolId poolId, ShareClassId shareClassId_, bytes32 investor, AssetId depositAssetId, uint32 endEpochId) public asAdmin {
        singleShareClass.claimDepositUntilEpoch(poolId, shareClassId_, investor, depositAssetId, endEpochId);
    }

    function singleShareClass_claimRedeemUntilEpoch(PoolId poolId, ShareClassId shareClassId_, bytes32 investor, AssetId payoutAssetId, uint32 endEpochId) public asAdmin {
        singleShareClass.claimRedeemUntilEpoch(poolId, shareClassId_, investor, payoutAssetId, endEpochId);
    }

    function singleShareClass_issueSharesUntilEpoch(PoolId poolId, ShareClassId shareClassId_, AssetId depositAssetId, D18 navPerShare, uint32 endEpochId) public asAdmin {
        singleShareClass.issueSharesUntilEpoch(poolId, shareClassId_, depositAssetId, navPerShare, endEpochId);
    }

    function singleShareClass_revokeSharesUntilEpoch(PoolId poolId, ShareClassId shareClassId_, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation, uint32 endEpochId) public asAdmin {
        singleShareClass.revokeSharesUntilEpoch(poolId, shareClassId_, payoutAssetId, navPerShare, valuation, endEpochId);
    }

    function singleShareClass_updateMetadata(PoolId poolId, ShareClassId shareClassId_, string memory name, string memory symbol, bytes32 salt, bytes memory data) public asActor {
        singleShareClass.updateMetadata(PoolId(poolId), ShareClassId(shareClassId_), name, symbol, salt, data);
    }
}