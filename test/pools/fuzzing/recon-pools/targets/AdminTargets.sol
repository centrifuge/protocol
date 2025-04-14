// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";
import {MockERC20} from "@recon/MockERC20.sol";

// Dependencies
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {JournalEntry} from "src/common/libraries/JournalEntryLib.sol";

// Interfaces
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

// Types
import {AccountId} from "src/common/types/AccountId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {D18} from "src/misc/types/D18.sol";

// Test Utils
import {BeforeAfter, OpType} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";
import {Helpers} from "../utils/Helpers.sol";

abstract contract AdminTargets is
    BaseTargetFunctions,
    Properties
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// === STATE FUNCTIONS === ///
    /// @dev these all add to the queuedCalls array, which is then executed in the execute_clamped function allowing the fuzzer to execute multiple calls in a single transaction
    /// @dev These explicitly clamp the investor to always be one of the actors
    /// @dev Queuing calls is done by the admin even though there is no asAdmin modifier applied because there are no external calls so using asAdmin creates errors  

    function hub_addCredit(uint64 poolIdAsUint, uint32 accountAsInt, uint128 amount) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        AccountId account = AccountId.wrap(accountAsInt);
        hub.addCredit(poolId, account, amount);
    }

    function hub_addDebit(uint64 poolIdAsUint, uint32 accountAsInt, uint128 amount) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        AccountId account = AccountId.wrap(accountAsInt);
        hub.addDebit(poolId, account, amount);
    }

    function hub_addShareClass(uint64 poolIdAsUint, uint256 salt) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        string memory name = "Test ShareClass";
        string memory symbol = "TSC";
        bytes memory data = "not-used";
        hub.addShareClass(poolId, name, symbol, bytes32(salt), data);
    }

    function hub_addShareClass_clamped(uint64 poolIdEntropy, uint256 salt) public {
        PoolId poolId = _getRandomPoolId(poolIdEntropy);
        hub_addShareClass(poolId.raw(), salt);
    }

    function hub_allowPoolAdmin(uint64 poolIdAsUint, address account, bool allow) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        hub.allowPoolAdmin(poolId, account, allow);
    }

    function hub_approveDeposits(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 paymentAssetIdAsUint, uint128 maxApproval, IERC7726 valuation) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId paymentAssetId = AssetId.wrap(paymentAssetIdAsUint);
        hub.approveDeposits(poolId, scId, paymentAssetId, maxApproval, valuation);
    }

    function hub_approveDeposits_clamped(uint64 poolIdEntropy, uint32 scEntropy, uint128 maxApproval, bool isIdentityValuation) public {
        PoolId poolId = _getRandomPoolId(poolIdEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        AssetId paymentAssetId = hubRegistry.currency(poolId);
        IERC7726 valuation = isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation));
        hub.approveDeposits(poolId, scId, paymentAssetId, maxApproval, valuation);
    }

    function hub_approveRedeems(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint128 maxApproval) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId payoutAssetId = AssetId.wrap(assetIdAsUint);
        hub.approveRedeems(poolId, scId, payoutAssetId, maxApproval);
    }

    function hub_approveRedeems_clamped(uint64 poolIdEntropy, uint32 scEntropy, uint128 maxApproval) public {
        PoolId poolId = _getRandomPoolId(poolIdEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        AssetId payoutAssetId = hubRegistry.currency(poolId);
        hub.approveRedeems(poolId, scId, payoutAssetId, maxApproval);
    }

    function hub_createAccount(uint64 poolIdAsUint, uint32 accountAsInt, bool isDebitNormal) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        AccountId account = AccountId.wrap(accountAsInt);
        hub.createAccount(poolId, account, isDebitNormal);
    }

    function hub_createHolding(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, IERC7726 valuation, bool isLiability, uint24 prefix) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.createHolding(poolId, scId, assetId, valuation, isLiability, prefix);
    }

    function hub_createHolding_clamped(uint64 poolIdEntropy, uint32 scEntropy, bool isIdentityValuation, bool isLiability, uint24 prefix) public {
        PoolId poolId = _getRandomPoolId(poolIdEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        IERC7726 valuation = isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation));
        hub_createHolding(poolId.raw(), scId.raw(), assetId.raw(), valuation, isLiability, prefix);
    }

    function hub_issueShares(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint128 navPerShare) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.issueShares(poolId, scId, assetId, D18.wrap(navPerShare));
    }

    function hub_issueShares_clamped(uint64 poolIdEntropy, uint32 scEntropy, uint128 navPerShare) public {
        PoolId poolId = _getRandomPoolId(poolIdEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        hub.issueShares(poolId, scId, assetId, D18.wrap(navPerShare));
    }

    function hub_notifyPool(uint64 poolIdAsUint, uint16 centrifugeId) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        hub.notifyPool(poolId, centrifugeId);
    }

    function hub_notifyShareClass(uint64 poolIdAsUint, uint16 centrifugeId, bytes16 scIdAsBytes, bytes32 hook) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.notifyShareClass(poolId, centrifugeId, scId, hook);
    }

    function hub_revokeShares(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint128 navPerShare, IERC7726 valuation) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId payoutAssetId = AssetId.wrap(assetIdAsUint);
        hub.revokeShares(poolId, scId, payoutAssetId, D18.wrap(navPerShare), valuation);
    }

    function hub_revokeShares_clamped(uint64 poolIdEntropy, uint32 scEntropy, uint128 navPerShare, bool isIdentityValuation) public {
        PoolId poolId = _getRandomPoolId(poolIdEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        AssetId payoutAssetId = hubRegistry.currency(poolId);
        IERC7726 valuation = isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation));
        hub.revokeShares(poolId, scId, payoutAssetId, D18.wrap(navPerShare), valuation);
    }

    function hub_setAccountMetadata(uint64 poolIdAsUint, uint32 accountAsInt, bytes memory metadata) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        AccountId account = AccountId.wrap(accountAsInt);
        hub.setAccountMetadata(poolId, account, metadata);
    }

    function hub_setHoldingAccountId(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint32 accountIdAsInt) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        AccountId accountId = AccountId.wrap(accountIdAsInt);
        hub.setHoldingAccountId(poolId, scId, assetId, accountId);
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

    function hub_updateRestriction(uint64 poolIdAsUint, uint16 chainId, bytes16 scIdAsBytes, bytes calldata payload) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.updateRestriction(poolId, chainId, scId, payload);
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    // === PoolManager === //
    /// Gateway owner methods: these get called directly because we're not using the gateway in our setup
    /// @notice These don't prank asAdmin because there are external calls first, 
    /// @notice admin is the tester contract (address(this)) so we leave out an explicit prank directly before the call to the target function

    function hub_registerAsset(uint32 isoCode) public updateGhosts {
        AssetId assetId_ = newAssetId(isoCode); 
        uint8 decimals = MockERC20(_getAsset()).decimals();

        hub.registerAsset(assetId_, decimals);
    }  

    /// @dev Property: after successfully calling requestDeposit for an investor, their depositRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: _updateDepositRequest should never revert due to underflow
    /// @dev Property: The total pending deposit amount pendingDeposit[..] is always >= the sum of pending user deposit amounts depositRequest[..]
    function hub_depositRequest(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 amount) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId depositAssetId = hubRegistry.currency(poolId);
        bytes32 investor = Helpers.addressToBytes32(_getActor());

        try hub.depositRequest(poolId, scId, investor, depositAssetId, amount) {
            deposited = true;

            (uint128 pending, uint32 lastUpdate) = shareClassManager.depositRequest(scId, depositAssetId, investor);
            uint32 epochId = shareClassManager.epochId(poolId);
            (uint32 latestApproval,,,) = shareClassManager.epochPointers(scId, depositAssetId);

            address[] memory _actors = _getActors();
            uint128 totalPendingDeposit = shareClassManager.pendingDeposit(scId, depositAssetId);
            uint128 totalPendingUserDeposit = 0;
            for (uint256 k = 0; k < _actors.length; k++) {
                address actor = _actors[k];
                (uint128 pendingUserDeposit,) = shareClassManager.depositRequest(scId, depositAssetId, Helpers.addressToBytes32(actor));
                totalPendingUserDeposit += pendingUserDeposit;
            }

            // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should not change
            if(_canMutate(lastUpdate, pending, latestApproval)) {
                eq(lastUpdate, epochId, "lastUpdate is not equal to epochId"); 
                gte(totalPendingDeposit, totalPendingUserDeposit, "total pending deposit is less than sum of pending user deposit amounts"); 
            }
        } catch (bytes memory reason) {
            bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
            t(!arithmeticRevert, "depositRequest reverts with arithmetic panic");
        }  
    }   

    function hub_depositRequest_clamped(uint64 poolIdEntropy, uint32 scEntropy, uint128 amount) public updateGhosts {
        PoolId poolId = _getRandomPoolId(poolIdEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        hub_depositRequest(poolId.raw(), scId.raw(), amount);
    }

    /// @dev Property: After successfully calling redeemRequest for an investor, their redeemRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: _updateRedeemRequest should never revert due to underflow
    function hub_redeemRequest(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint128 amount) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId payoutAssetId = AssetId.wrap(assetIdAsUint);
        bytes32 investor = Helpers.addressToBytes32(_getActor());

        try hub.redeemRequest(poolId, scId, investor, payoutAssetId, amount) {
            (, uint32 lastUpdate) = shareClassManager.redeemRequest(scId, payoutAssetId, investor);
            uint32 epochId = shareClassManager.epochId(poolId);

            eq(lastUpdate, epochId, "lastUpdate is not equal to epochId after redeemRequest");
        } catch (bytes memory reason) {
            bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
            t(!arithmeticRevert, "redeemRequest reverts with arithmetic panic");
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
    /// @dev Property: _updateDepositRequest should never revert due to underflow
    /// @dev Property: The total pending deposit amount pendingDeposit[..] is always >= the sum of pending user deposit amounts depositRequest[..]
    function hub_cancelDepositRequest(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint32 isoCode) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId depositAssetId = newAssetId(isoCode);
        bytes32 investor = Helpers.addressToBytes32(_getActor());

        (uint128 pendingBefore, uint32 lastUpdateBefore) = shareClassManager.depositRequest(scId, depositAssetId, investor);
        (uint32 latestApproval,,,) = shareClassManager.epochPointers(scId, depositAssetId);
        try hub.cancelDepositRequest(poolId, scId, investor, depositAssetId) {
            (uint128 pending, uint32 lastUpdate) = shareClassManager.depositRequest(scId, depositAssetId, investor);
            uint32 epochId = shareClassManager.epochId(poolId);

            // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should not change
            if(_canMutate(lastUpdateBefore, pendingBefore, latestApproval)) {
                eq(lastUpdate, epochId, "lastUpdate is not equal to current epochId");
                eq(pending, 0, "pending is not zero");
            }
        } catch (bytes memory reason) {
            uint32 epochId = shareClassManager.epochId(poolId);
            uint128 previousDepositApproved;
            if(epochId > 0) {
                // we also check the previous epoch because approvals can increment the epochId
                (,previousDepositApproved,,,,,) = shareClassManager.epochAmounts(scId, depositAssetId, epochId - 1);
            }
            (,uint128 currentDepositApproved,,,,,) = shareClassManager.epochAmounts(scId, depositAssetId, epochId);
            // we only care about arithmetic reverts in the case of 0 approvals because if there have been any approvals, it's expected that user won't be able to cancel their request 
            if(previousDepositApproved == 0 && currentDepositApproved == 0) {
                bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
                t(!arithmeticRevert, "cancelDepositRequest reverts with arithmetic panic");
            }
        }
    }

    /// @dev Property: After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].pending is zero
    /// @dev Property: cancelRedeemRequest absolute value should never be higher than pendingRedeem (would result in underflow revert)
    function hub_cancelRedeemRequest(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint32 isoCode) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId payoutAssetId = newAssetId(isoCode);
        bytes32 investor = Helpers.addressToBytes32(_getActor());

        try hub.cancelRedeemRequest(poolId, scId, investor, payoutAssetId) {
            (uint128 pending, uint32 lastUpdate) = shareClassManager.redeemRequest(scId, payoutAssetId, investor);
            uint32 epochId = shareClassManager.epochId(poolId);

            eq(lastUpdate, epochId, "lastUpdate is not equal to current epochId after cancelRedeemRequest");
            eq(pending, 0, "pending is not zero after cancelRedeemRequest");
        } catch (bytes memory reason) {
            uint32 epochId = shareClassManager.epochId(poolId);
            uint128 previousRedeemApproved;
            if(epochId > 0) {
                // we also check the previous epoch because approvals can increment the epochId
                (,,,,, previousRedeemApproved,) = shareClassManager.epochAmounts(scId, payoutAssetId, epochId - 1);
            }
            (,,,,, uint128 currentRedeemApproved,) = shareClassManager.epochAmounts(scId, payoutAssetId, epochId);
            // we only care about arithmetic reverts in the case of 0 approvals because if there have been any approvals, it's expected that user won't be able to cancel their request 
            if(previousRedeemApproved == 0 && currentRedeemApproved == 0) {
                bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
                t(!arithmeticRevert, "cancelRedeemRequest reverts with arithmetic panic");
            }
        }
    }

    function hub_updateHoldingAmount(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint128 amount, uint128 pricePerUnit, bool isIncrease, JournalEntry[] memory debits, JournalEntry[] memory credits) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.updateHoldingAmount(poolId, scId, assetId, amount, D18.wrap(pricePerUnit), isIncrease, debits, credits);
    }

    function hub_updateHoldingAmount_clamped(uint64 poolEntropy, uint32 scEntropy, uint8 accountEntropy, uint128 amount, uint128 pricePerUnit, bool isIncrease) public updateGhosts {
        PoolId poolId = _getRandomPoolId(poolEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);

        JournalEntry[] memory debits = new JournalEntry[](1);
        debits[0] = JournalEntry({
            accountId: _getRandomAccountId(poolId, scId, assetId, accountEntropy),
            amount: amount
        });
        JournalEntry[] memory credits = new JournalEntry[](1);
        credits[0] = JournalEntry({
            accountId: _getRandomAccountId(poolId, scId, assetId, accountEntropy),
            amount: amount
        });

        hub_updateHoldingAmount(poolId.raw(), scId.raw(), assetId.raw(), amount, pricePerUnit, isIncrease, debits, credits);
    }

    function hub_updateHoldingValue(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint128 pricePerUnit) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.updateHoldingValue(poolId, scId, assetId, D18.wrap(pricePerUnit));
    }

    function hub_updateHoldingValue_clamped(uint64 poolEntropy, uint32 scEntropy, uint128 pricePerUnit) public updateGhosts {
        PoolId poolId = _getRandomPoolId(poolEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        hub_updateHoldingValue(poolId.raw(), scId.raw(), assetId.raw(), pricePerUnit);
    }

    function hub_updateJournal(uint64 poolIdAsUint, JournalEntry[] memory debits, JournalEntry[] memory credits) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        hub.updateJournal(poolId, debits, credits);
    }

    function hub_increaseShareIssuance(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 pricePerShare, uint128 amount) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.increaseShareIssuance(poolId, scId, D18.wrap(pricePerShare), amount);
    }

    function hub_increaseShareIssuance_clamped(uint64 poolEntropy, uint32 scEntropy, uint128 pricePerShare, uint128 amount) public updateGhosts {
        PoolId poolId = _getRandomPoolId(poolEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        hub.increaseShareIssuance(poolId, scId, D18.wrap(pricePerShare), amount);
    }

    function hub_decreaseShareIssuance(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 pricePerShare, uint128 amount) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.decreaseShareIssuance(poolId, scId, D18.wrap(pricePerShare), amount);
    }

    function hub_decreaseShareIssuance_clamped(uint64 poolEntropy, uint32 scEntropy, uint128 pricePerShare, uint128 amount) public updateGhosts {
        PoolId poolId = _getRandomPoolId(poolEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        hub.decreaseShareIssuance(poolId, scId, D18.wrap(pricePerShare), amount);
    }

    // === ShareClassManager === //

    function shareClassManager_claimDepositUntilEpoch(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint32 endEpochId) public updateGhosts asAdmin {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId shareClassId_ = ShareClassId.wrap(scIdAsBytes);
        bytes32 investor = Helpers.addressToBytes32(_getActor());
        AssetId depositAssetId = AssetId.wrap(assetIdAsUint);

        shareClassManager.claimDepositUntilEpoch(poolId, shareClassId_, investor, depositAssetId, endEpochId);
    }

    function shareClassManager_claimRedeemUntilEpoch(uint64 poolIdAsUint, bytes16 scIdAsBytes, bytes32 investor, uint128 assetIdAsUint, uint32 endEpochId) public updateGhosts asAdmin {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId shareClassId_ = ShareClassId.wrap(scIdAsBytes);
        AssetId payoutAssetId = AssetId.wrap(assetIdAsUint);
        shareClassManager.claimRedeemUntilEpoch(poolId, shareClassId_, investor, payoutAssetId, endEpochId);
    }

    function shareClassManager_issueSharesUntilEpoch(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint128 navPerShare, uint32 endEpochId) public updateGhosts asAdmin {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId shareClassId_ = ShareClassId.wrap(scIdAsBytes);
        AssetId depositAssetId = AssetId.wrap(assetIdAsUint);
        shareClassManager.issueSharesUntilEpoch(poolId, shareClassId_, depositAssetId, D18.wrap(navPerShare), endEpochId);
    }

    function shareClassManager_revokeSharesUntilEpoch(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, D18 navPerShare, IERC7726 valuation, uint32 endEpochId) public updateGhosts asAdmin {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId shareClassId_ = ShareClassId.wrap(scIdAsBytes);
        AssetId payoutAssetId = AssetId.wrap(assetIdAsUint);
        shareClassManager.revokeSharesUntilEpoch(poolId, shareClassId_, payoutAssetId, navPerShare, valuation, endEpochId);
    }

    function shareClassManager_updateMetadata(uint64 poolIdAsUint, bytes16 scIdAsBytes, string memory name, string memory symbol, bytes32 salt) public updateGhosts asActor {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId shareClassId_ = ShareClassId.wrap(scIdAsBytes);
        bytes memory data = "not-used";
        shareClassManager.updateMetadata(poolId, shareClassId_, name, symbol, salt, data);
    }
}