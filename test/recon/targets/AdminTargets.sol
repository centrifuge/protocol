 // SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {vm} from "@chimera/Hevm.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";
import {MockERC20} from "@recon/MockERC20.sol";

// Source
import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
import "src/pools/PoolManager.sol";

import {BeforeAfter} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";
import {Helpers} from "../utils/Helpers.sol";

abstract contract AdminTargets is
    BaseTargetFunctions,
    Properties
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// === STATE FUNCTIONS === ///
    /// NOTE: these all add to the queuedCalls array, which is then executed in the execute_clamped function allowing the fuzzer to execute multiple calls in a single transaction
    /// These explicitly clamp the investor to always be one of the actors
    /// Queuing calls is done by the admin even though there is no asAdmin modifier applied because there are no external calls so using asAdmin creates errors  

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

    function poolRouter_claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId) public {
        bytes32 investor = Helpers.addressToBytes32(_getActor());
        queuedCalls.push(abi.encodeWithSelector(poolRouter.claimDeposit.selector, poolId, scId, assetId, investor));
    }

    function poolRouter_claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId) public {
        bytes32 investor = Helpers.addressToBytes32(_getActor());
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

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    // === PoolManager === //
    /// Gateway owner methods: these get called directly because we're not using the gateway in our setup

    function poolManager_registerAsset(uint32 isoCode) public asAdmin {
        AssetId assetId_ = newAssetId(isoCode); 

        string memory name = MockERC20(_getAsset()).name();
        string memory symbol = MockERC20(_getAsset()).symbol();
        uint8 decimals = MockERC20(_getAsset()).decimals();

        poolManager.registerAsset(assetId_, name, symbol, decimals);
    }  

    function poolManager_depositRequest(PoolId poolId, ShareClassId scId, uint32 isoCode, uint128 amount) public asAdmin {
        AssetId depositAssetId = newAssetId(isoCode);
        bytes32 investor = Helpers.addressToBytes32(_getActor());

        poolManager.depositRequest(poolId, scId, investor, depositAssetId, amount);
    }  

    function poolManager_redeemRequest(PoolId poolId, ShareClassId scId, uint32 isoCode, uint128 amount) public asAdmin {
        AssetId payoutAssetId = newAssetId(isoCode);
        bytes32 investor = Helpers.addressToBytes32(_getActor());

        poolManager.redeemRequest(poolId, scId, investor, payoutAssetId, amount);
    }  

    function poolManager_cancelDepositRequest(PoolId poolId, ShareClassId scId, AssetId depositAssetId) public asAdmin {
        bytes32 investor = Helpers.addressToBytes32(_getActor());

        poolManager.cancelDepositRequest(poolId, scId, investor, depositAssetId);
    }

    function poolManager_cancelRedeemRequest(PoolId poolId, ShareClassId scId, AssetId payoutAssetId) public asAdmin {
        bytes32 investor = Helpers.addressToBytes32(_getActor());

        poolManager.cancelRedeemRequest(poolId, scId, investor, payoutAssetId);
    }

    // === PoolRouter === //

    function poolRouter_execute(PoolId poolId, bytes[] memory data) public payable asAdmin {
        poolRouter.execute{value: msg.value}(poolId, data);
    }

    function poolRouter_execute_clamped(PoolId poolId) public payable asAdmin {
        // TODO: clamp poolId here to one of the created pools
        poolRouter.execute{value: msg.value}(poolId, queuedCalls);

        queuedCalls = new bytes[](0);
    }

    // === SingleShareClass === //

    function singleShareClass_claimDepositUntilEpoch(PoolId poolId, ShareClassId shareClassId_, AssetId depositAssetId, uint32 endEpochId) public asAdmin {
        bytes32 investor = Helpers.addressToBytes32(_getActor());

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