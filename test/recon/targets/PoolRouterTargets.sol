// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {BeforeAfter} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";
// Chimera deps
import {vm} from "@chimera/Hevm.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";

import "src/pools/PoolRouter.sol";

abstract contract PoolRouterTargets is
    BaseTargetFunctions,
    Properties
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///


    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function poolRouter_addCredit(AccountId account, uint128 amount) public asActor {
        poolRouter.addCredit(account, amount);
    }

    function poolRouter_addDebit(AccountId account, uint128 amount) public asActor {
        poolRouter.addDebit(account, amount);
    }

    function poolRouter_addShareClass(string memory name, string memory symbol, bytes32 salt, bytes memory data) public asActor {
        poolRouter.addShareClass(name, symbol, salt, data);
    }

    function poolRouter_allowAsset(ShareClassId scId, AssetId assetId, bool allow) public asActor {
        poolRouter.allowAsset(scId, assetId, allow);
    }

    function poolRouter_allowPoolAdmin(address account, bool allow) public asActor {
        poolRouter.allowPoolAdmin(account, allow);
    }

    function poolRouter_approveDeposits(ShareClassId scId, AssetId paymentAssetId, uint128 maxApproval, IERC7726 valuation) public asActor {
        poolRouter.approveDeposits(scId, paymentAssetId, maxApproval, valuation);
    }

    function poolRouter_approveRedeems(ShareClassId scId, AssetId payoutAssetId, uint128 maxApproval) public asActor {
        poolRouter.approveRedeems(scId, payoutAssetId, maxApproval);
    }

    function poolRouter_claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) public asAdmin {
        poolRouter.claimDeposit(poolId, scId, assetId, investor);
    }

    function poolRouter_claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) public asActor {
        poolRouter.claimRedeem(poolId, scId, assetId, investor);
    }

    function poolRouter_createAccount(AccountId account, bool isDebitNormal) public asActor {
        poolRouter.createAccount(account, isDebitNormal);
    }

    function poolRouter_createHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint24 prefix) public asActor {
        poolRouter.createHolding(scId, assetId, valuation, prefix);
    }

    function poolRouter_createPool(AssetId currency, IShareClassManager shareClassManager) public asActor {
        poolRouter.createPool(currency, shareClassManager);
    }

    function poolRouter_decreaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount) public asActor {
        poolRouter.decreaseHolding(scId, assetId, valuation, amount);
    }

    function poolRouter_execute(PoolId poolId, bytes[] memory data) public payable asActor {
        poolRouter.execute{value: msg.value}(poolId, data);
    }

    function poolRouter_increaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount) public asActor {
        poolRouter.increaseHolding(scId, assetId, valuation, amount);
    }

    function poolRouter_issueShares(ShareClassId scId, AssetId depositAssetId, D18 navPerShare) public asActor {
        poolRouter.issueShares(scId, depositAssetId, navPerShare);
    }

    function poolRouter_multicall(bytes[] memory data) public payable asActor {
        poolRouter.multicall{value: msg.value}(data);
    }

    function poolRouter_notifyPool(uint32 chainId) public asActor {
        poolRouter.notifyPool(chainId);
    }

    function poolRouter_notifyShareClass(uint32 chainId, ShareClassId scId, bytes32 hook) public asActor {
        poolRouter.notifyShareClass(chainId, scId, hook);
    }

    function poolRouter_revokeShares(ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation) public asActor {
        poolRouter.revokeShares(scId, payoutAssetId, navPerShare, valuation);
    }

    function poolRouter_setAccountMetadata(AccountId account, bytes memory metadata) public asActor {
        poolRouter.setAccountMetadata(account, metadata);
    }

    function poolRouter_setHoldingAccountId(ShareClassId scId, AssetId assetId, AccountId accountId) public asActor {
        poolRouter.setHoldingAccountId(scId, assetId, accountId);
    }

    function poolRouter_setPoolMetadata(bytes memory metadata) public asActor {
        poolRouter.setPoolMetadata(metadata);
    }

    function poolRouter_updateHolding(ShareClassId scId, AssetId assetId) public asActor {
        poolRouter.updateHolding(scId, assetId);
    }

    function poolRouter_updateHoldingValuation(ShareClassId scId, AssetId assetId, IERC7726 valuation) public asActor {
        poolRouter.updateHoldingValuation(scId, assetId, valuation);
    }
}