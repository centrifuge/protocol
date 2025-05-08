// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {console2} from "forge-std/console2.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";
import {MockERC20} from "@recon/MockERC20.sol";

// Dependencies
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {JournalEntry} from "src/hub/interfaces/IAccounting.sol";

// Interfaces
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

// Types
import {AccountId} from "src/common/types/AccountId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {D18} from "src/misc/types/D18.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

// Test Utils
import {BeforeAfter, OpType} from "test/integration/recon-end-to-end/BeforeAfter.sol";
import {Properties} from "test/integration/recon-end-to-end/properties/Properties.sol";
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";
import {console2} from "forge-std/console2.sol";

abstract contract AdminTargets is
    BaseTargetFunctions,
    Properties
{
    using CastLib for *;

    event InterestingCoverageLog();

    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// === STATE FUNCTIONS === ///
    /// @dev These explicitly clamp the investor to always be one of the actors

    function hub_addShareClass(uint256 salt) public {
        PoolId poolId = PoolId.wrap(_getPool());
        string memory name = "Test ShareClass";
        string memory symbol = "TSC";
        hub.addShareClass(poolId, name, symbol, bytes32(salt));
    }

    function hub_approveDeposits(uint32 nowDepositEpochId, uint128 maxApproval) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId paymentAssetId = hubRegistry.currency(poolId);
        uint128 pendingDepositBefore = shareClassManager.pendingDeposit(scId, paymentAssetId);
        
        hub.approveDeposits(poolId, scId, paymentAssetId, nowDepositEpochId, maxApproval);

        uint128 pendingDepositAfter = shareClassManager.pendingDeposit(scId, paymentAssetId);
        uint128 approvedAssetAmount = pendingDepositBefore - pendingDepositAfter;
        approvedDeposits += approvedAssetAmount;
    }

    function hub_approveRedeems(uint128 assetIdAsUint, uint32 nowRedeemEpochId, uint128 maxApproval) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId payoutAssetId = AssetId.wrap(assetIdAsUint);
        uint128 pendingRedeemBefore = shareClassManager.pendingRedeem(scId, payoutAssetId);
        
        hub.approveRedeems(poolId, scId, payoutAssetId, nowRedeemEpochId, maxApproval);

        uint128 pendingRedeemAfter = shareClassManager.pendingRedeem(scId, payoutAssetId);
        uint128 approvedAssetAmount = pendingRedeemBefore - pendingRedeemAfter;
        approvedRedemptions += approvedAssetAmount;
    }

    function hub_approveRedeems_clamped(uint32 nowRedeemEpochId, uint128 maxApproval) public {
        PoolId poolId = PoolId.wrap(_getPool());
        AssetId payoutAssetId = hubRegistry.currency(poolId);
        hub_approveRedeems(payoutAssetId.raw(), nowRedeemEpochId, maxApproval);
    }

    function hub_createAccount(uint32 accountAsInt, bool isDebitNormal) public {
        PoolId poolId = PoolId.wrap(_getPool());
        AccountId account = AccountId.wrap(accountAsInt);
        hub.createAccount(poolId, account, isDebitNormal);

        createdAccountIds.push(account);
    }

    function hub_createHolding(IERC7726 valuation, uint32 assetAccountAsUint, uint32 equityAccountAsUint, uint32 lossAccountAsUint, uint32 gainAccountAsUint) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = hubRegistry.currency(poolId);

        hub.createHolding(
            poolId, 
            scId, 
            assetId, 
            valuation, 
            AccountId.wrap(assetAccountAsUint), 
            AccountId.wrap(equityAccountAsUint), 
            AccountId.wrap(lossAccountAsUint), 
            AccountId.wrap(gainAccountAsUint)
        );    
    }

    function hub_createHolding_clamped(bool isIdentityValuation, uint8 assetAccountEntropy, uint8 equityAccountEntropy, uint8 lossAccountEntropy, uint8 gainAccountEntropy) public {
        IERC7726 valuation = isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation));
        AccountId assetAccount = Helpers.getRandomAccountId(createdAccountIds, assetAccountEntropy);
        AccountId equityAccount = Helpers.getRandomAccountId(createdAccountIds, equityAccountEntropy);
        AccountId lossAccount = Helpers.getRandomAccountId(createdAccountIds, lossAccountEntropy);
        AccountId gainAccount = Helpers.getRandomAccountId(createdAccountIds, gainAccountEntropy);

        hub_createHolding(valuation, assetAccount.raw(), equityAccount.raw(), lossAccount.raw(), gainAccount.raw());
    }

    function hub_createLiability(uint128 assetIdAsUint, IERC7726 valuation, uint32 expenseAccountAsUint, uint32 liabilityAccountAsUint) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.createLiability(poolId, scId, assetId, valuation, AccountId.wrap(expenseAccountAsUint), AccountId.wrap(liabilityAccountAsUint));
    }
    
    function hub_createLiability_clamped(bool isIdentityValuation, uint8 expenseAccountEntropy, uint8 liabilityAccountEntropy) public {
        PoolId poolId = PoolId.wrap(_getPool());
        AssetId assetId = hubRegistry.currency(poolId);
        IERC7726 valuation = isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation));
        AccountId expenseAccount = Helpers.getRandomAccountId(createdAccountIds, expenseAccountEntropy);
        AccountId liabilityAccount = Helpers.getRandomAccountId(createdAccountIds, liabilityAccountEntropy);
        
        hub_createLiability(assetId.raw(), valuation, expenseAccount.raw(), liabilityAccount.raw());
    }
    
    function hub_issueShares(uint128 assetIdAsUint, uint32 nowIssueEpochId, uint128 navPerShare) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.issueShares(poolId, scId, assetId, nowIssueEpochId, D18.wrap(navPerShare));
    }

    function hub_issueShares_clamped(uint32 nowIssueEpochId, uint128 navPerShare) public {
        PoolId poolId = PoolId.wrap(_getPool());
        AssetId assetId = hubRegistry.currency(poolId);
        hub_issueShares(assetId.raw(), nowIssueEpochId, navPerShare);
    }

    function hub_notifyPool(uint16 centrifugeId) public {
        PoolId poolId = PoolId.wrap(_getPool());
        hub.notifyPool(poolId, centrifugeId);
    }

    function hub_notifyPool_clamped() public {
        hub_notifyPool(CENTRIFUGE_CHAIN_ID);
    }

    function hub_notifyShareClass(uint16 centrifugeId, bytes32 hook) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        hub.notifyShareClass(poolId, scId, centrifugeId, hook);
    }

    function hub_notifyShareClass_clamped(bytes32 hook) public {
        hub_notifyShareClass(CENTRIFUGE_CHAIN_ID, hook);
    }

    function hub_notifySharePrice(uint16 centrifugeId) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        hub.notifySharePrice(poolId, scId, centrifugeId);
    }

    function hub_notifySharePrice_clamped() public {
        hub_notifySharePrice(CENTRIFUGE_CHAIN_ID);
    }
    
    function hub_notifyAssetPrice() public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = hubRegistry.currency(poolId);
        hub.notifyAssetPrice(poolId, scId, assetId);
    }

    function hub_triggerIssueShares(uint16 centrifugeId, uint128 shares) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        hub.triggerIssueShares(centrifugeId, poolId, scId, _getActor(), shares);
    }
    
    function hub_triggerIssueShares_clamped(uint128 shares) public {
        hub_triggerIssueShares(CENTRIFUGE_CHAIN_ID, shares);
    }

    function hub_triggerSubmitQueuedShares(uint16 centrifugeId) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        hub.triggerSubmitQueuedShares(centrifugeId, poolId, scId);
    }

    function hub_triggerSubmitQueuedShares_clamped() public {
        hub_triggerSubmitQueuedShares(CENTRIFUGE_CHAIN_ID);
    }

    function hub_triggerSubmitQueuedAssets(uint128 assetIdAsUint) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.triggerSubmitQueuedAssets(poolId, scId, assetId);
    }

    function hub_triggerSubmitQueuedAssets_clamped() public {
        PoolId poolId = PoolId.wrap(_getPool());
        AssetId assetId = hubRegistry.currency(poolId);
        hub_triggerSubmitQueuedAssets(assetId.raw());
    }
    
    function hub_setQueue(uint16 centrifugeId, bool enabled) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        hub.setQueue(centrifugeId, poolId, scId, enabled);
    }

    function hub_setQueue_clamped(bool enabled) public {
        hub_setQueue(CENTRIFUGE_CHAIN_ID, enabled);
    }

    function hub_revokeShares(uint32 nowRevokeEpochId, uint128 navPerShare) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId payoutAssetId = hubRegistry.currency(poolId);
        hub.revokeShares(poolId, scId, payoutAssetId, nowRevokeEpochId, D18.wrap(navPerShare));
    }

    function hub_setAccountMetadata(uint32 accountAsInt, bytes memory metadata) public {
        PoolId poolId = PoolId.wrap(_getPool());
        AccountId account = AccountId.wrap(accountAsInt);
        hub.setAccountMetadata(poolId, account, metadata);
    }

    function hub_setHoldingAccountId(uint128 assetIdAsUint, uint8 kind, uint32 accountIdAsInt) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        AccountId accountId = AccountId.wrap(accountIdAsInt);   
        hub.setHoldingAccountId(poolId, scId, assetId, kind, accountId);
    }

    function hub_setPoolMetadata(bytes memory metadata) public {
        PoolId poolId = PoolId.wrap(_getPool());
        hub.setPoolMetadata(poolId, metadata);
    }

    function hub_updateHoldingValuation(uint128 assetIdAsUint, IERC7726 valuation) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.updateHoldingValuation(poolId, scId, assetId, valuation);
    }

    function hub_updateHoldingValuation_clamped(bool isIdentityValuation) public {
        PoolId poolId = PoolId.wrap(_getPool());
        AssetId assetId = hubRegistry.currency(poolId);
        IERC7726 valuation = isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation));
        hub_updateHoldingValuation(assetId.raw(), valuation);
    }

    function hub_updateRestriction(uint16 chainId, bytes calldata payload) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        hub.updateRestriction(poolId, scId, chainId, payload);
    }

    function hub_updateRestriction_clamped(bytes calldata payload) public {
        hub_updateRestriction(CENTRIFUGE_CHAIN_ID, payload);
    }

    function hub_updatePricePerShare(uint128 navPerShare) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        hub.updatePricePerShare(poolId, scId, D18.wrap(navPerShare));
    }

    function syncRequestManager_setValuation(address valuation) public {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        syncRequestManager.setValuation(poolId, scId, valuation);
    }

    function syncRequestManager_setValuation_clamped(bool isIdentityValuation) public {
        address valuation = isIdentityValuation ? address(identityValuation) : address(transientValuation);
        syncRequestManager_setValuation(valuation);
    }
    
    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    // === PoolManager === //
    /// Gateway owner methods: these get called directly because we're not using the gateway in our setup
    /// @notice These don't prank asAdmin because there are external calls first, 
    /// @notice admin is the tester contract (address(this)) so we leave out an explicit prank directly before the call to the target function
    /// NOTE: commented functions don't need to have handlers anymore because they're called as callbacks to operations in the Vault 

    // function hub_registerAsset(uint128 assetIdAsUint) public updateGhosts {
    //     AssetId assetId_ = AssetId.wrap(assetIdAsUint); 
    //     uint8 decimals = MockERC20(_getAsset()).decimals();

    //     hub.registerAsset(assetId_, decimals);

    //     createdAssetIds.push(assetId_);
    // }  

    // function hub_registerAsset_clamped() public updateGhosts {
    //     uint128 assetId = assetAddressToAssetId[_getAsset()];
    //     hub_registerAsset(assetId);
    // }

    /// @dev Property: after successfully calling requestDeposit for an investor, their depositRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: _updateDepositRequest should never revert due to underflow
    /// @dev Property: The total pending deposit amount pendingDeposit[..] is always >= the sum of pending user deposit amounts depositRequest[..]
    // function hub_depositRequest(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 amount) public updateGhosts {
    //     PoolId poolId = PoolId.wrap(poolIdAsUint);
    //     ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
    //     AssetId depositAssetId = hubRegistry.currency(poolId);

    // function hub_increaseShareIssuance(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 amount) public updateGhosts {
    //     PoolId poolId = PoolId.wrap(poolIdAsUint);
    //     ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
    //     hub.increaseShareIssuance(poolId, scId, amount);
    // }

    // function hub_increaseShareIssuance_clamped(uint64 poolEntropy, uint32 scEntropy, uint128 pricePerShare, uint128 amount) public updateGhosts {
    //     PoolId poolId = Helpers.getRandomPoolId(_getPools(), poolEntropy);
    //     ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
    //     hub_increaseShareIssuance(poolId.raw(), scId.raw(), amount);
    // }

    // function hub_decreaseShareIssuance(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 amount) public updateGhosts {
    //     PoolId poolId = PoolId.wrap(poolIdAsUint);
    //     ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
    //     hub.decreaseShareIssuance(poolId, scId, amount);
    // }

    // function hub_decreaseShareIssuance_clamped(uint64 poolEntropy, uint32 scEntropy, uint128 amount) public updateGhosts {
    //     PoolId poolId = Helpers.getRandomPoolId(_getPools(), poolEntropy);
    //     ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
    //     hub_decreaseShareIssuance(poolId.raw(), scId.raw(), amount);
    // }
}