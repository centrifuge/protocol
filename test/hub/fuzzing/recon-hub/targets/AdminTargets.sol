// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

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
import {BeforeAfter, OpType} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";
import {Helpers} from "../utils/Helpers.sol";
import {console2} from "forge-std/console2.sol";

abstract contract AdminTargets is
    BaseTargetFunctions,
    Properties
{
    using CastLib for *;

    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// === STATE FUNCTIONS === ///
    /// @dev these all add to the queuedCalls array, which is then executed in the execute_clamped function allowing the fuzzer to execute multiple calls in a single transaction
    /// @dev These explicitly clamp the investor to always be one of the actors
    /// @dev Queuing calls is done by the admin even though there is no asAdmin modifier applied because there are no external calls so using asAdmin creates errors  

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
    }

    function hub_initializeHolding(uint64 poolIdAsUint, bytes16 scIdAsBytes, IERC7726 valuation, uint32 assetAccountAsUint, uint32 equityAccountAsUint, uint32 lossAccountAsUint, uint32 gainAccountAsUint) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = hubRegistry.currency(poolId);

        hub.initializeHolding(
            poolId, 
            scId, 
            assetId, 
            valuation, 
            AccountId.wrap(assetAccountAsUint), 
            AccountId.wrap(equityAccountAsUint), 
            AccountId.wrap(lossAccountAsUint), 
            AccountId.wrap(gainAccountAsUint)
        );

        // store the created accountIds for clamping 
        createdAccountIds.push(AccountId.wrap(assetAccountAsUint));
        createdAccountIds.push(AccountId.wrap(equityAccountAsUint));
        createdAccountIds.push(AccountId.wrap(lossAccountAsUint));
        createdAccountIds.push(AccountId.wrap(gainAccountAsUint));    
    }

    function hub_initializeHolding_clamped(uint64 poolIdEntropy, uint32 scEntropy, bool isIdentityValuation, uint32 assetAccountAsUint, uint32 equityAccountAsUint, uint32 lossAccountAsUint, uint32 gainAccountAsUint) public {
        PoolId poolId = _getRandomPoolId(poolIdEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        IERC7726 valuation = isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation));

        hub_initializeHolding(poolId.raw(), scId.raw(), valuation, assetAccountAsUint, equityAccountAsUint, lossAccountAsUint, gainAccountAsUint);
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

    function hub_updateRestriction(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint16 chainId, bytes calldata payload) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.updateRestriction(poolId, scId, chainId, payload);
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    // === PoolManager === //
    /// Gateway owner methods: these get called directly because we're not using the gateway in our setup
    /// @notice These don't prank asAdmin because there are external calls first, 
    /// @notice admin is the tester contract (address(this)) so we leave out an explicit prank directly before the call to the target function
    
    function hub_registerAsset(uint128 assetIdAsUint) public updateGhosts {
        AssetId assetId_ = AssetId.wrap(assetIdAsUint); 
        uint8 decimals = MockERC20(_getAsset()).decimals();

        hub.registerAsset(assetId_, decimals);

        // store the created assetId for clamping 
        createdAssetIds.push(assetId_);
    }  

    /// @dev Property: after successfully calling requestDeposit for an investor, their depositRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: _updateDepositRequest should never revert due to underflow
    function hub_depositRequest(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 amount) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId depositAssetId = hubRegistry.currency(poolId);
        bytes32 investor = _getActor().toBytes32();

        try hub.depositRequest(poolId, scId, investor, depositAssetId, amount) {
            (uint128 pending, uint32 lastUpdate) = shareClassManager.depositRequest(scId, depositAssetId, investor);
            (uint32 depositEpochId,,, )= shareClassManager.epochId(scId, depositAssetId);

            // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should not change
            if(Helpers.canMutate(lastUpdate, pending, depositEpochId)) {
                eq(lastUpdate, depositEpochId, "lastUpdate != depositEpochId"); 
            }
        } catch (bytes memory reason) {
            // precondition: check that it wasn't an overflow because we only care about underflow
            uint128 pendingDeposit = shareClassManager.pendingDeposit(scId, depositAssetId);
            if(uint256(pendingDeposit) + uint256(amount) < uint256(type(uint128).max)) {
                bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
                t(!arithmeticRevert, "depositRequest reverts with arithmetic panic");
            }
        }  
    }    

    function hub_depositRequest_clamped(uint64 poolIdEntropy, uint32 scEntropy, uint128 amount) public updateGhosts {
        PoolId poolId = _getRandomPoolId(poolIdEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        hub_depositRequest(poolId.raw(), scId.raw(), amount);
    }

    /// @dev Property: After successfully calling redeemRequest for an investor, their redeemRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    function hub_redeemRequest(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint128 amount) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId payoutAssetId = AssetId.wrap(assetIdAsUint);
        bytes32 investor = CastLib.toBytes32(_getActor());

        try hub.redeemRequest(poolId, scId, investor, payoutAssetId, amount) {
            (, uint32 lastUpdate) = shareClassManager.redeemRequest(scId, payoutAssetId, investor);
            // uint32 epochId = shareClassManager.epochId(poolId);

            // eq(lastUpdate, epochId, "lastUpdate is not equal to epochId after redeemRequest");
        } catch {
        }
    }  

    function hub_redeemRequest_clamped(uint64 poolIdEntropy, uint32 scEntropy, uint128 amount) public updateGhosts {
        PoolId poolId = _getRandomPoolId(poolIdEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        AssetId payoutAssetId = hubRegistry.currency(poolId);
        hub_redeemRequest(poolId.raw(), scId.raw(), payoutAssetId.raw(), amount);
    }

    /// @dev The investor is explicitly clamped to one of the actors to make checking properties over all actors easier 
    /// @dev Property: after successfully calling cancelDepositRequest for an investor, their depositRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: after successfully calling cancelDepositRequest for an investor, their depositRequest[..].pending is zero
    /// @dev Property: cancelDepositRequest absolute value should never be higher than pendingDeposit (would result in underflow revert)
    function hub_cancelDepositRequest(uint64 poolIdAsUint, bytes16 scIdAsBytes) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId depositAssetId = hubRegistry.currency(poolId);
        bytes32 investor = _getActor().toBytes32();

        (uint128 pendingBefore, uint32 lastUpdateBefore) = shareClassManager.depositRequest(scId, depositAssetId, investor);
        (uint32 depositEpochId,,, )= shareClassManager.epochId(scId, depositAssetId);
        try hub.cancelDepositRequest(poolId, scId, investor, depositAssetId) {
            (uint128 pendingAfter, uint32 lastUpdateAfter) = shareClassManager.depositRequest(scId, depositAssetId, investor);

            // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should not change
            if(Helpers.canMutate(lastUpdateBefore, pendingBefore, depositEpochId)) {
                eq(lastUpdateAfter, depositEpochId, "lastUpdate != depositEpochId");
                eq(pendingAfter, 0, "pending is not zero");
            }
        } catch (bytes memory reason) {
            (uint32 depositEpochId,,,) = shareClassManager.epochId(scId, depositAssetId);
            uint128 previousDepositApproved;
            if(depositEpochId > 0) {
                // we also check the previous epoch because approvals can increment the epochId
                (, previousDepositApproved,,,,) = shareClassManager.epochInvestAmounts(scId, depositAssetId, depositEpochId - 1);
            }
            (, uint128 currentDepositApproved,,,,) = shareClassManager.epochInvestAmounts(scId, depositAssetId, depositEpochId);
            // we only care about arithmetic reverts in the case of 0 approvals because if there have been any approvals, it's expected that user won't be able to cancel their request 
            if(previousDepositApproved == 0 && currentDepositApproved == 0) {
                bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
                t(!arithmeticRevert, "cancelDepositRequest reverts with arithmetic panic");
            }
        }
    }

    function hub_cancelDepositRequest_clamped(uint64 poolIdEntropy, uint32 scEntropy) public updateGhosts {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        hub_cancelDepositRequest(poolId.raw(), scId.raw());
    }

    /// @dev Property: After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].pending is zero
    /// @dev Property: cancelRedeemRequest absolute value should never be higher than pendingRedeem (would result in underflow revert)
    function hub_cancelRedeemRequest(uint64 poolIdAsUint, bytes16 scIdAsBytes) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId payoutAssetId = hubRegistry.currency(poolId);
        bytes32 investor = _getActor().toBytes32();

        (uint128 pendingBefore, uint32 lastUpdateBefore) = shareClassManager.redeemRequest(scId, payoutAssetId, investor);

        try hub.cancelRedeemRequest(poolId, scId, investor, payoutAssetId) {
            (uint128 pendingAfter, uint32 lastUpdateAfter) = shareClassManager.redeemRequest(scId, payoutAssetId, investor);
            (, uint32 redeemEpochId,, )= shareClassManager.epochId(scId, payoutAssetId);

            // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should not change
            if(Helpers.canMutate(lastUpdateBefore, pendingBefore, redeemEpochId)) {
                eq(lastUpdateAfter, redeemEpochId, "lastUpdate != redeemEpochId");
                eq(pendingAfter, 0, "pending != 0");
            }
        } catch (bytes memory reason) {
            (, uint32 redeemEpochId,, )= shareClassManager.epochId(scId, payoutAssetId);
            uint128 previousRedeemApproved;
            if(redeemEpochId > 0) {
                // we also check the previous epoch because approvals can increment the epochId
                (, previousRedeemApproved,,,,) = shareClassManager.epochInvestAmounts(scId, payoutAssetId, redeemEpochId - 1);
            }
            (, uint128 currentRedeemApproved,,,,) = shareClassManager.epochInvestAmounts(scId, payoutAssetId, redeemEpochId);
            // we only care about arithmetic reverts in the case of 0 approvals because if there have been any approvals, it's expected that user won't be able to cancel their request 
            if(previousRedeemApproved == 0 && currentRedeemApproved == 0) {
                bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
                t(!arithmeticRevert, "cancelRedeemRequest reverts with arithmetic panic");
            }
        }
    }

    function hub_cancelRedeemRequest_clamped(uint64 poolIdEntropy, uint32 scEntropy) public updateGhosts {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        hub_cancelRedeemRequest(poolId.raw(), scId.raw());
    }

    function hub_updateHoldingAmount(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint128 amount, uint128 pricePerUnit, bool isIncrease) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.updateHoldingAmount(poolId, scId, assetId, amount, D18.wrap(pricePerUnit), isIncrease);
    }

    function hub_updateHoldingAmount_clamped(uint64 poolEntropy, uint32 scEntropy, uint8 accountEntropy, uint128 amount, uint128 pricePerUnit, bool isIncrease) public updateGhosts {
        PoolId poolId = _getRandomPoolId(poolEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);

        JournalEntry[] memory debits = new JournalEntry[](1);
        debits[0] = JournalEntry({
            value: amount,
            accountId: _getRandomAccountId(poolId, scId, assetId, accountEntropy)
        });
        JournalEntry[] memory credits = new JournalEntry[](1);
        credits[0] = JournalEntry({
            value: amount,
            accountId: _getRandomAccountId(poolId, scId, assetId, accountEntropy)
        });

        hub_updateHoldingAmount(poolId.raw(), scId.raw(), assetId.raw(), amount, pricePerUnit, isIncrease);
    }

    function hub_updateHoldingValue(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.updateHoldingValue(poolId, scId, assetId);
    }

    function hub_updateHoldingValue_clamped(uint64 poolEntropy, uint32 scEntropy) public updateGhosts {
        PoolId poolId = _getRandomPoolId(poolEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        hub_updateHoldingValue(poolId.raw(), scId.raw(), assetId.raw());
    }

    function hub_updateJournal(uint64 poolIdAsUint, JournalEntry[] memory debits, JournalEntry[] memory credits) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        hub.updateJournal(poolId, debits, credits);
    }

    function hub_increaseShareIssuance(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 amount) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.increaseShareIssuance(poolId, scId, amount);
    }

    function hub_increaseShareIssuance_clamped(uint64 poolEntropy, uint32 scEntropy, uint128 amount) public updateGhosts {
        PoolId poolId = _getRandomPoolId(poolEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        hub_increaseShareIssuance(poolId.raw(), scId.raw(), amount);
    }

    function hub_decreaseShareIssuance(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 amount) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.decreaseShareIssuance(poolId, scId, amount);
    }

    function hub_decreaseShareIssuance_clamped(uint64 poolEntropy, uint32 scEntropy, uint128 amount) public updateGhosts {
        PoolId poolId = _getRandomPoolId(poolEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        hub_decreaseShareIssuance(poolId.raw(), scId.raw(), amount);
    }
}