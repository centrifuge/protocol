// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {vm} from "@chimera/Hevm.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";

import {BeforeAfter} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";

import "src/pools/PoolRouter.sol";
import "src/misc/interfaces/IERC7726.sol";

abstract contract PoolRouterTargets is
    BaseTargetFunctions,
    Properties
{
    bytes[] internal queuedCalls;

    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    
    /// === STATE FUNCTIONS === ///
    /// NOTE: these all add to the queuedCalls array, which is then executed in the execute_clamped function allowing the fuzzer to execute multiple calls in a single transaction

    function poolRouter_addCredit(AccountId account, uint128 amount) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.addCredit.selector, account, amount));
    }

    function poolRouter_addDebit(AccountId account, uint128 amount) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.addDebit.selector, account, amount));
    }

    function poolRouter_addShareClass(string memory name, string memory symbol, bytes32 salt, bytes memory data) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.addShareClass.selector, name, symbol, salt, data));
    }

    function poolRouter_allowAsset(ShareClassId scId, AssetId assetId, bool allow) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.allowAsset.selector, scId, assetId, allow));
    }

    function poolRouter_allowPoolAdmin(address account, bool allow) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.allowPoolAdmin.selector, account, allow));
    }

    function poolRouter_approveDeposits(ShareClassId scId, AssetId paymentAssetId, uint128 maxApproval, IERC7726 valuation) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.approveDeposits.selector, scId, paymentAssetId, maxApproval, valuation));
    }

    function poolRouter_approveRedeems(ShareClassId scId, AssetId payoutAssetId, uint128 maxApproval) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.approveRedeems.selector, scId, payoutAssetId, maxApproval));
    }

    function poolRouter_claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.claimDeposit.selector, poolId, scId, assetId, investor));
    }

    function poolRouter_claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.claimRedeem.selector, poolId, scId, assetId, investor));
    }

    function poolRouter_createAccount(AccountId account, bool isDebitNormal) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.createAccount.selector, account, isDebitNormal));
    }

    function poolRouter_createHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint24 prefix) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.createHolding.selector, scId, assetId, valuation, prefix));
    }

    function poolRouter_createPool(AssetId currency, IShareClassManager shareClassManager) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.createPool.selector, currency, shareClassManager));
    }

    function poolRouter_decreaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.decreaseHolding.selector, scId, assetId, valuation, amount));
    }

    function poolRouter_increaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.increaseHolding.selector, scId, assetId, valuation, amount));
    }

    function poolRouter_issueShares(ShareClassId scId, AssetId depositAssetId, D18 navPerShare) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.issueShares.selector, scId, depositAssetId, navPerShare));
    }

    function poolRouter_notifyPool(uint32 chainId) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.notifyPool.selector, chainId));
    }

    function poolRouter_notifyShareClass(uint32 chainId, ShareClassId scId, bytes32 hook) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.notifyShareClass.selector, chainId, scId, hook));
    }

    function poolRouter_revokeShares(ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.revokeShares.selector, scId, payoutAssetId, navPerShare, valuation));
    }

    function poolRouter_setAccountMetadata(AccountId account, bytes memory metadata) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.setAccountMetadata.selector, account, metadata));
    }

    function poolRouter_setHoldingAccountId(ShareClassId scId, AssetId assetId, AccountId accountId) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.setHoldingAccountId.selector, scId, assetId, accountId));
    }

    function poolRouter_setPoolMetadata(bytes memory metadata) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.setPoolMetadata.selector, metadata));
    }

    function poolRouter_updateHolding(ShareClassId scId, AssetId assetId) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.updateHolding.selector, scId, assetId));
    }

    function poolRouter_updateHoldingValuation(ShareClassId scId, AssetId assetId, IERC7726 valuation) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.updateHoldingValuation.selector, scId, assetId, valuation));
    }

    /// === SHORTCUT FUNCTIONS === ///
    // NOTE: these are shortcuts for the most common calls
    function poolRouter_add_share_class_and_holding(
        string memory name, 
        string memory symbol, 
        bytes32 salt, 
        bytes memory data, 
        ShareClassId scId, 
        AssetId assetId, 
        uint8 valuationIndex, 
        uint24 prefix) public 
        {
        poolRouter_addShareClass(name, symbol, salt, data);

        valuationIndex %= 2;
        IERC7726 valuation;
        if (valuationIndex == 0) {
            valuation = identityValuation;
        } else {
            valuation = transientValuation;
        }

        poolRouter_createHolding(scId, assetId, valuation, prefix);
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
    
    /// === EXECUTION FUNCTIONS === ///
    function poolRouter_execute(PoolId poolId, bytes[] memory data) public payable asActor {
        poolRouter.execute{value: msg.value}(poolId, data);
    }

    function poolRouter_execute_clamped(PoolId poolId) public payable asActor {
        // TODO: clamp poolId here to one of the created pools
        poolRouter.execute{value: msg.value}(poolId, queuedCalls);
    }

    function poolRouter_multicall(bytes[] memory data) public payable asActor {
        poolRouter.multicall{value: msg.value}(data);
    }
}