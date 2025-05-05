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

    function hub_addShareClass(uint64 poolIdAsUint, uint256 salt) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        string memory name = "Test ShareClass";
        string memory symbol = "TSC";
        hub.addShareClass(poolId, name, symbol, bytes32(salt));
    }

    function hub_addShareClass_clamped(uint64 poolIdEntropy, uint256 salt) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        hub_addShareClass(poolId.raw(), salt);
    }

    function hub_approveDeposits(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 paymentAssetIdAsUint, uint32 nowDepositEpochId, uint128 maxApproval) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId paymentAssetId = AssetId.wrap(paymentAssetIdAsUint);
        uint128 pendingDepositBefore = shareClassManager.pendingDeposit(scId, paymentAssetId);
        
        hub.approveDeposits(poolId, scId, paymentAssetId, nowDepositEpochId, maxApproval);

        uint128 pendingDepositAfter = shareClassManager.pendingDeposit(scId, paymentAssetId);
        uint128 approvedAssetAmount = pendingDepositBefore - pendingDepositAfter;
        approvedDeposits += approvedAssetAmount;
    }

    function hub_approveDeposits_clamped(uint64 poolIdEntropy, uint32 scEntropy, uint32 nowDepositEpochId, uint128 maxApproval) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        AssetId paymentAssetId = hubRegistry.currency(poolId);
        hub_approveDeposits(poolId.raw(), scId.raw(), paymentAssetId.raw(), nowDepositEpochId, maxApproval);
    }

    function hub_approveRedeems(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint32 nowRedeemEpochId, uint128 maxApproval) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId payoutAssetId = AssetId.wrap(assetIdAsUint);
        uint128 pendingRedeemBefore = shareClassManager.pendingRedeem(scId, payoutAssetId);
        
        hub.approveRedeems(poolId, scId, payoutAssetId, nowRedeemEpochId, maxApproval);

        uint128 pendingRedeemAfter = shareClassManager.pendingRedeem(scId, payoutAssetId);
        uint128 approvedAssetAmount = pendingRedeemBefore - pendingRedeemAfter;
        approvedRedemptions += approvedAssetAmount;
    }

    function hub_approveRedeems_clamped(uint64 poolIdEntropy, uint32 scEntropy, uint32 nowRedeemEpochId, uint128 maxApproval) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        AssetId payoutAssetId = hubRegistry.currency(poolId);
        hub_approveRedeems(poolId.raw(), scId.raw(), payoutAssetId.raw(), nowRedeemEpochId, maxApproval);
    }

    function hub_createAccount(uint64 poolIdAsUint, uint32 accountAsInt, bool isDebitNormal) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        AccountId account = AccountId.wrap(accountAsInt);
        hub.createAccount(poolId, account, isDebitNormal);

        createdAccountIds.push(account);
    }

    function hub_createAccount_clamped(uint64 poolIdEntropy, uint32 accountAsInt, bool isDebitNormal) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        hub_createAccount(poolId.raw(), accountAsInt, isDebitNormal);
    }

    function hub_createHolding(uint64 poolIdAsUint, bytes16 scIdAsBytes, IERC7726 valuation, uint32 assetAccountAsUint, uint32 equityAccountAsUint, uint32 lossAccountAsUint, uint32 gainAccountAsUint) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
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

    function hub_createHolding_clamped(uint64 poolIdEntropy, uint32 scEntropy, bool isIdentityValuation, uint8 assetAccountEntropy, uint8 equityAccountEntropy, uint8 lossAccountEntropy, uint8 gainAccountEntropy) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        IERC7726 valuation = isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation));
        AccountId assetAccount = Helpers.getRandomAccountId(createdAccountIds, assetAccountEntropy);
        AccountId equityAccount = Helpers.getRandomAccountId(createdAccountIds, equityAccountEntropy);
        AccountId lossAccount = Helpers.getRandomAccountId(createdAccountIds, lossAccountEntropy);
        AccountId gainAccount = Helpers.getRandomAccountId(createdAccountIds, gainAccountEntropy);

        hub_createHolding(poolId.raw(), scId.raw(), valuation, assetAccount.raw(), equityAccount.raw(), lossAccount.raw(), gainAccount.raw());
    }

    function hub_createLiability(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, IERC7726 valuation, uint32 expenseAccountAsUint, uint32 liabilityAccountAsUint) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.createLiability(poolId, scId, assetId, valuation, AccountId.wrap(expenseAccountAsUint), AccountId.wrap(liabilityAccountAsUint));
    }
    
    function hub_createLiability_clamped(uint64 poolIdEntropy, uint32 scEntropy, bool isIdentityValuation, uint8 expenseAccountEntropy, uint8 liabilityAccountEntropy) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        IERC7726 valuation = isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation));
        AccountId expenseAccount = Helpers.getRandomAccountId(createdAccountIds, expenseAccountEntropy);
        AccountId liabilityAccount = Helpers.getRandomAccountId(createdAccountIds, liabilityAccountEntropy);
        
        hub_createLiability(poolId.raw(), scId.raw(), assetId.raw(), valuation, expenseAccount.raw(), liabilityAccount.raw());
    }
    
    function hub_issueShares(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint32 nowIssueEpochId, uint128 navPerShare) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.issueShares(poolId, scId, assetId, nowIssueEpochId, D18.wrap(navPerShare));
    }

    function hub_issueShares_clamped(uint64 poolIdEntropy, uint32 scEntropy, uint32 nowIssueEpochId,  uint128 navPerShare) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        hub_issueShares(poolId.raw(), scId.raw(), assetId.raw(), nowIssueEpochId, navPerShare);
    }

    function hub_notifyPool(uint64 poolIdAsUint, uint16 centrifugeId) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        hub.notifyPool(poolId, centrifugeId);
    }

    function hub_notifyPool_clamped(uint64 poolIdEntropy) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        hub_notifyPool(poolId.raw(), CENTIFUGE_CHAIN_ID);
    }

    function hub_notifyShareClass(uint64 poolIdAsUint, uint16 centrifugeId, bytes16 scIdAsBytes, bytes32 hook) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.notifyShareClass(poolId, scId, centrifugeId, hook);
    }

    function hub_notifyShareClass_clamped(uint64 poolIdEntropy, uint32 scEntropy, bytes32 hook) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        hub_notifyShareClass(poolId.raw(), CENTIFUGE_CHAIN_ID, scId.raw(), hook);
    }

    function hub_notifySharePrice(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint16 centrifugeId) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.notifySharePrice(poolId, scId, centrifugeId);
    }

    function hub_notifySharePrice_clamped(uint64 poolIdEntropy, uint32 scEntropy) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        hub_notifySharePrice(poolId.raw(), scId.raw(), CENTIFUGE_CHAIN_ID);
    }
    
    function hub_notifyAssetPrice(uint64 poolIdAsUint, bytes16 scIdAsBytes) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = hubRegistry.currency(poolId);
        hub.notifyAssetPrice(poolId, scId, assetId);
    }

    function hub_notifyAssetPrice_clamped(uint64 poolIdEntropy, uint32 scEntropy) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        hub_notifyAssetPrice(poolId.raw(), scId.raw());
    }

    function hub_triggerIssueShares(uint16 centrifugeId, uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 shares) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.triggerIssueShares(centrifugeId, poolId, scId, _getActor(), shares);
    }
    
    function hub_triggerIssueShares_clamped(uint64 poolIdEntropy, uint32 scEntropy, uint128 shares) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        hub_triggerIssueShares(CENTIFUGE_CHAIN_ID, poolId.raw(), scId.raw(), shares);
    }

    function hub_triggerSubmitQueuedShares(uint16 centrifugeId, uint64 poolIdAsUint, bytes16 scIdAsBytes) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.triggerSubmitQueuedShares(centrifugeId, poolId, scId);
    }

    function hub_triggerSubmitQueuedShares_clamped(uint64 poolIdEntropy, uint32 scEntropy) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        hub_triggerSubmitQueuedShares(CENTIFUGE_CHAIN_ID, poolId.raw(), scId.raw());
    }

    function hub_triggerSubmitQueuedAssets(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.triggerSubmitQueuedAssets(poolId, scId, assetId);
    }

    function hub_triggerSubmitQueuedAssets_clamped(uint64 poolIdEntropy, uint32 scEntropy) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        hub_triggerSubmitQueuedAssets(poolId.raw(), scId.raw(), assetId.raw());
    }
    
    function hub_setQueue(uint16 centrifugeId, uint64 poolIdAsUint, bytes16 scIdAsBytes, bool enabled) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.setQueue(centrifugeId, poolId, scId, enabled);
    }

    function hub_setQueue_clamped(uint64 poolIdEntropy, uint32 scEntropy, bool enabled) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        hub_setQueue(CENTIFUGE_CHAIN_ID, poolId.raw(), scId.raw(), enabled);
    }

    function hub_revokeShares(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint32 nowRevokeEpochId, uint128 navPerShare) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId payoutAssetId = hubRegistry.currency(poolId);
        hub.revokeShares(poolId, scId, payoutAssetId, nowRevokeEpochId, D18.wrap(navPerShare));
    }

    function hub_revokeShares_clamped(uint64 poolIdEntropy, uint32 scEntropy, uint128 navPerShare, uint32 nowRevokeEpochId) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        hub_revokeShares(poolId.raw(), scId.raw(), nowRevokeEpochId, navPerShare);
    }

    function hub_setAccountMetadata(uint64 poolIdAsUint, uint32 accountAsInt, bytes memory metadata) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        AccountId account = AccountId.wrap(accountAsInt);
        hub.setAccountMetadata(poolId, account, metadata);
    }

    function hub_setHoldingAccountId(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint8 kind, uint32 accountIdAsInt) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        AccountId accountId = AccountId.wrap(accountIdAsInt);   
        hub.setHoldingAccountId(poolId, scId, assetId, kind, accountId);
    }

    function hub_setPoolMetadata(uint64 poolIdAsUint, bytes memory metadata) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        hub.setPoolMetadata(poolId, metadata);
    }

    function hub_updateHoldingValuation(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, IERC7726 valuation) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.updateHoldingValuation(poolId, scId, assetId, valuation);
    }

    function hub_updateHoldingValuation_clamped(uint64 poolIdEntropy, uint32 scEntropy, bool isIdentityValuation) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        IERC7726 valuation = isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation));
        hub_updateHoldingValuation(poolId.raw(), scId.raw(), assetId.raw(), valuation);
    }

    function hub_updateRestriction(uint64 poolIdAsUint, uint16 chainId, bytes16 scIdAsBytes, bytes calldata payload) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.updateRestriction(poolId, scId, chainId, payload);
    }

    function hub_updateRestriction_clamped(uint64 poolIdEntropy, uint32 scEntropy, bytes calldata payload) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        hub_updateRestriction(poolId.raw(), CENTIFUGE_CHAIN_ID, scId.raw(), payload);
    }

    function hub_updatePricePerShare(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 navPerShare) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.updatePricePerShare(poolId, scId, D18.wrap(navPerShare));
    }

    function hub_updatePricePerShare_clamped(uint64 poolIdEntropy, uint32 scEntropy, uint128 navPerShare) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        hub_updatePricePerShare(poolId.raw(), scId.raw(), navPerShare);
    } 

    function syncRequestManager_setValuation(uint64 poolIdAsUint, bytes16 scIdAsBytes, address valuation) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        syncRequestManager.setValuation(poolId, scId, valuation);
    }

    function syncRequestManager_setValuation_clamped(uint64 poolIdAsUint, uint32 scIdAsUint, bool isIdentityValuation) public {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdAsUint);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scIdAsUint);
        address valuation = isIdentityValuation ? address(identityValuation) : address(transientValuation);
        syncRequestManager_setValuation(poolId.raw(), scId.raw(), valuation);
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
    //     bytes32 investor = _getActor().toBytes32();

    //     try hub.depositRequest(poolId, scId, investor, depositAssetId, amount) {
    //         (uint128 pending, uint32 lastUpdate) = shareClassManager.depositRequest(scId, depositAssetId, investor);
    //         (uint32 depositEpochId,,, )= shareClassManager.epochId(scId, depositAssetId);

    //         // ghost tracking
    //         requestDeposited[_getActor()] += amount;

    //         address[] memory _actors = _getActors();
    //         uint128 totalPendingDeposit = shareClassManager.pendingDeposit(scId, depositAssetId);
    //         uint128 totalPendingUserDeposit = 0;
    //         for (uint256 k = 0; k < _actors.length; k++) {
    //             address actor = _actors[k];
    //             (uint128 pendingUserDeposit,) = shareClassManager.depositRequest(scId, depositAssetId, actor.toBytes32());
    //             totalPendingUserDeposit += pendingUserDeposit;
    //         }

    //         // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should not change
    //         if(Helpers.canMutate(lastUpdate, pending, depositEpochId)) {
    //             // eq(lastUpdate, depositEpochId, "lastUpdate != depositEpochId"); 
    //             gte(totalPendingDeposit, totalPendingUserDeposit, "total pending deposit < sum of pending user deposit amounts"); 
    //         }

    //         // state space enrichment
    //         if(amount > 0) {
    //             emit InterestingCoverageLog();
    //         }
    //     } catch (bytes memory reason) {
    //         // precondition: check that it wasn't an overflow because we only care about underflow
    //         uint128 pendingDeposit = shareClassManager.pendingDeposit(scId, depositAssetId);
    //         if(uint256(pendingDeposit) + uint256(amount) < uint256(type(uint128).max)) {
    //             bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
    //             t(!arithmeticRevert, "depositRequest reverts with arithmetic panic");
    //         }
    //     }  
    // }   

    // function hub_depositRequest_clamped(uint64 poolIdEntropy, uint32 scEntropy, uint128 amount) public updateGhosts {
    //     PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
    //     ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
    //     hub_depositRequest(poolId.raw(), scId.raw(), amount);
    // }

    /// @dev Property: After successfully calling redeemRequest for an investor, their redeemRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    // function hub_redeemRequest(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint128 amount) public updateGhosts {
    //     PoolId poolId = PoolId.wrap(poolIdAsUint);
    //     ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
    //     AssetId payoutAssetId = AssetId.wrap(assetIdAsUint);
    //     bytes32 investor = _getActor().toBytes32();

    //     try hub.redeemRequest(poolId, scId, investor, payoutAssetId, amount) {
    //         // ghost tracking
    //         requestRedeeemed[_getActor()] += amount;

    //         (, uint32 lastUpdate) = shareClassManager.redeemRequest(scId, payoutAssetId, investor);
    //         (, uint32 redeemEpochId,, ) = shareClassManager.epochId(scId, payoutAssetId);

    //         eq(lastUpdate, redeemEpochId, "lastUpdate is not equal to epochId after redeemRequest");

    //         // state space enrichment   
    //         if(amount > 0) {
    //             emit InterestingCoverageLog();
    //         }
    //     } catch {}
    // }  

    // function hub_redeemRequest_clamped(uint64 poolIdEntropy, uint32 scEntropy, uint128 amount) public updateGhosts {
    //     PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
    //     ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
    //     AssetId payoutAssetId = hubRegistry.currency(poolId);
    //     hub_redeemRequest(poolId.raw(), scId.raw(), payoutAssetId.raw(), amount);
    // }

    /// @dev The investor is explicitly clamped to one of the actors to make checking properties over all actors easier 
    /// @dev Property: after successfully calling cancelDepositRequest for an investor, their depositRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: after successfully calling cancelDepositRequest for an investor, their depositRequest[..].pending is zero
    /// @dev Property: cancelDepositRequest absolute value should never be higher than pendingDeposit (would result in underflow revert)
    /// @dev Property: _updateDepositRequest should never revert due to underflow
    /// @dev Property: The total pending deposit amount pendingDeposit[..] is always >= the sum of pending user deposit amounts depositRequest[..]
    // function hub_cancelDepositRequest(uint64 poolIdAsUint, bytes16 scIdAsBytes) public updateGhosts {
    //     PoolId poolId = PoolId.wrap(poolIdAsUint);
    //     ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
    //     AssetId depositAssetId = hubRegistry.currency(poolId);
    //     bytes32 investor = _getActor().toBytes32();

    //     (uint128 pendingBefore, uint32 lastUpdateBefore) = shareClassManager.depositRequest(scId, depositAssetId, investor);
    //     (uint32 depositEpochId,,, )= shareClassManager.epochId(scId, depositAssetId);
    //     try hub.cancelDepositRequest(poolId, scId, investor, depositAssetId) {
    //         (uint128 pendingAfter, uint32 lastUpdateAfter) = shareClassManager.depositRequest(scId, depositAssetId, investor);

    //         // update ghosts
    //         cancelledDeposits[_getActor()] += (pendingBefore - pendingAfter);

    //         // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should not change
    //         if(Helpers.canMutate(lastUpdateBefore, pendingBefore, depositEpochId)) {
    //             eq(lastUpdateAfter, depositEpochId, "lastUpdate != depositEpochId");
    //             eq(pendingAfter, 0, "pending is not zero");
    //         }
    //     } catch (bytes memory reason) {
    //         (uint32 depositEpochId,,,) = shareClassManager.epochId(scId, depositAssetId);
    //         uint128 previousDepositApproved;
    //         if(depositEpochId > 0) {
    //             // we also check the previous epoch because approvals can increment the epochId
    //             (, previousDepositApproved,,,,) = shareClassManager.epochInvestAmounts(scId, depositAssetId, depositEpochId - 1);
    //         }
    //         (, uint128 currentDepositApproved,,,,) = shareClassManager.epochInvestAmounts(scId, depositAssetId, depositEpochId);
    //         // we only care about arithmetic reverts in the case of 0 approvals because if there have been any approvals, it's expected that user won't be able to cancel their request 
    //         if(previousDepositApproved == 0 && currentDepositApproved == 0) {
    //             bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
    //             t(!arithmeticRevert, "cancelDepositRequest reverts with arithmetic panic");
    //         }
    //     }
    // }

    // function hub_cancelDepositRequest_clamped(uint64 poolIdEntropy, uint32 scEntropy) public updateGhosts {
    //     PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
    //     ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
    //     hub_cancelDepositRequest(poolId.raw(), scId.raw());
    // }

    /// @dev Property: After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].pending is zero
    /// @dev Property: cancelRedeemRequest absolute value should never be higher than pendingRedeem (would result in underflow revert)
    // function hub_cancelRedeemRequest(uint64 poolIdAsUint, bytes16 scIdAsBytes) public updateGhosts {
    //     PoolId poolId = PoolId.wrap(poolIdAsUint);
    //     ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
    //     AssetId payoutAssetId = hubRegistry.currency(poolId);
    //     bytes32 investor = _getActor().toBytes32();

    //     (uint128 pendingBefore, uint32 lastUpdateBefore) = shareClassManager.redeemRequest(scId, payoutAssetId, investor);

    //     try hub.cancelRedeemRequest(poolId, scId, investor, payoutAssetId) {
    //         (uint128 pendingAfter, uint32 lastUpdateAfter) = shareClassManager.redeemRequest(scId, payoutAssetId, investor);
    //         (, uint32 redeemEpochId,, )= shareClassManager.epochId(scId, payoutAssetId);

    //         // update ghosts
    //         cancelledRedemptions[_getActor()] += (pendingBefore - pendingAfter);

    //         // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should not change
    //         if(Helpers.canMutate(lastUpdateBefore, pendingBefore, redeemEpochId)) {
    //             eq(lastUpdateAfter, redeemEpochId, "lastUpdate != redeemEpochId");
    //             eq(pendingAfter, 0, "pending != 0");
    //         }
    //     } catch (bytes memory reason) {
    //         (, uint32 redeemEpochId,, )= shareClassManager.epochId(scId, payoutAssetId);
    //         uint128 previousRedeemApproved;
    //         if(redeemEpochId > 0) {
    //             // we also check the previous epoch because approvals can increment the epochId
    //             (, previousRedeemApproved,,,,) = shareClassManager.epochInvestAmounts(scId, payoutAssetId, redeemEpochId - 1);
    //         }
    //         (, uint128 currentRedeemApproved,,,,) = shareClassManager.epochInvestAmounts(scId, payoutAssetId, redeemEpochId);
    //         // we only care about arithmetic reverts in the case of 0 approvals because if there have been any approvals, it's expected that user won't be able to cancel their request 
    //         if(previousRedeemApproved == 0 && currentRedeemApproved == 0) {
    //             bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
    //             t(!arithmeticRevert, "cancelRedeemRequest reverts with arithmetic panic");
    //         }
    //     }
    // }

    // function hub_cancelRedeemRequest_clamped(uint64 poolIdEntropy, uint32 scEntropy) public updateGhosts {
    //     PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
    //     ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
    //     hub_cancelRedeemRequest(poolId.raw(), scId.raw());
    // }

    // function hub_updateHoldingAmount(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint128 amount, uint128 pricePerUnit, bool isIncrease) public updateGhosts {
    //     PoolId poolId = PoolId.wrap(poolIdAsUint);
    //     ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
    //     AssetId assetId = AssetId.wrap(assetIdAsUint);
    //     hub.updateHoldingAmount(poolId, scId, assetId, amount, D18.wrap(pricePerUnit), isIncrease);
    // }

    // function hub_updateHoldingAmount_clamped(uint64 poolEntropy, uint32 scEntropy, uint8 accountEntropy, uint128 amount, uint128 pricePerUnit, bool isIncrease) public updateGhosts {
    //     PoolId poolId = Helpers.getRandomPoolId(createdPools, poolEntropy);
    //     ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
    //     AssetId assetId = hubRegistry.currency(poolId);

    //     JournalEntry[] memory debits = new JournalEntry[](1);
    //     debits[0] = JournalEntry({
    //         value: amount,
    //         accountId: Helpers.getRandomAccountId(holdings, poolId, scId, assetId, accountEntropy)
    //     });
    //     JournalEntry[] memory credits = new JournalEntry[](1);
    //     credits[0] = JournalEntry({
    //         value: amount,
    //         accountId: Helpers.getRandomAccountId(holdings, poolId, scId, assetId, accountEntropy)
    //     });

    //     hub_updateHoldingAmount(poolId.raw(), scId.raw(), assetId.raw(), amount, pricePerUnit, isIncrease);
    // }

    // NOTE: might potentially cause false positives because it's an admin function that's not regularly called
    function hub_updateHoldingValue(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.updateHoldingValue(poolId, scId, assetId);
    }

    function hub_updateHoldingValue_clamped(uint64 poolEntropy, uint32 scEntropy) public updateGhosts {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        hub_updateHoldingValue(poolId.raw(), scId.raw(), assetId.raw());
    }

    function hub_updateJournal(uint64 poolIdAsUint, JournalEntry[] memory debits, JournalEntry[] memory credits) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        hub.updateJournal(poolId, debits, credits);
    }

    function hub_updateJournal_clamped(uint64 poolIdEntropy, uint8 accountEntropy, uint128 amount) public updateGhosts {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        
        JournalEntry[] memory debits = new JournalEntry[](1);
        debits[0] = JournalEntry({
            value: amount,
            accountId: Helpers.getRandomAccountId(createdAccountIds, accountEntropy)
        });
        JournalEntry[] memory credits = new JournalEntry[](1);
        credits[0] = JournalEntry({
            value: amount,
            accountId: Helpers.getRandomAccountId(createdAccountIds, accountEntropy)
        });

        hub_updateJournal(poolId.raw(), debits, credits);
    }

    // function hub_increaseShareIssuance(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 amount) public updateGhosts {
    //     PoolId poolId = PoolId.wrap(poolIdAsUint);
    //     ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
    //     hub.increaseShareIssuance(poolId, scId, amount);
    // }

    // function hub_increaseShareIssuance_clamped(uint64 poolEntropy, uint32 scEntropy, uint128 pricePerShare, uint128 amount) public updateGhosts {
    //     PoolId poolId = Helpers.getRandomPoolId(createdPools, poolEntropy);
    //     ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
    //     hub_increaseShareIssuance(poolId.raw(), scId.raw(), amount);
    // }

    // function hub_decreaseShareIssuance(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 amount) public updateGhosts {
    //     PoolId poolId = PoolId.wrap(poolIdAsUint);
    //     ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
    //     hub.decreaseShareIssuance(poolId, scId, amount);
    // }

    // function hub_decreaseShareIssuance_clamped(uint64 poolEntropy, uint32 scEntropy, uint128 amount) public updateGhosts {
    //     PoolId poolId = Helpers.getRandomPoolId(createdPools, poolEntropy);
    //     ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
    //     hub_decreaseShareIssuance(poolId.raw(), scId.raw(), amount);
    // }
}