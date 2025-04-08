 // SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {vm} from "@chimera/Hevm.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";
import {MockERC20} from "@recon/MockERC20.sol";

// Source
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {JournalEntry} from "src/common/libraries/JournalEntryLib.sol";

import {BeforeAfter, OpType} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";
import {Helpers} from "../utils/Helpers.sol";

import "forge-std/console2.sol";

abstract contract AdminTargets is
    BaseTargetFunctions,
    Properties
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// === STATE FUNCTIONS === ///
    /// @dev these all add to the queuedCalls array, which is then executed in the execute_clamped function allowing the fuzzer to execute multiple calls in a single transaction
    /// @dev These explicitly clamp the investor to always be one of the actors
    /// @dev Queuing calls is done by the admin even though there is no asAdmin modifier applied because there are no external calls so using asAdmin creates errors  

    function hub_addCredit(uint32 accountAsInt, uint128 amount) public {
        AccountId account = AccountId.wrap(accountAsInt);
        queuedCalls.push(abi.encodeWithSelector(hub.addCredit.selector, account, amount));
    }

    function hub_addDebit(uint32 accountAsInt, uint128 amount) public {
        AccountId account = AccountId.wrap(accountAsInt);
        queuedCalls.push(abi.encodeWithSelector(hub.addDebit.selector, account, amount));
    }

    function hub_addShareClass(bytes32 salt) public {
        string memory name = "Test ShareClass";
        string memory symbol = "TSC";
        bytes memory data = "not-used";
        queuedCalls.push(abi.encodeWithSelector(hub.addShareClass.selector, name, symbol, salt, data));
    }

    function hub_allowPoolAdmin(address account, bool allow) public {
        queuedCalls.push(abi.encodeWithSelector(hub.allowPoolAdmin.selector, account, allow));
    }

    function hub_approveDeposits(bytes16 scIdAsBytes, uint128 paymentAssetIdAsUint, uint128 maxApproval, IERC7726 valuation) public {
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId paymentAssetId = AssetId.wrap(paymentAssetIdAsUint);
        queuedCalls.push(abi.encodeWithSelector(hub.approveDeposits.selector, scId, paymentAssetId, maxApproval, valuation));
    }

    function hub_approveRedeems(bytes16 scIdAsBytes, uint32 isoCode, uint128 maxApproval) public {
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId payoutAssetId = newAssetId(isoCode);
        
        queuedCalls.push(abi.encodeWithSelector(hub.approveRedeems.selector, scId, payoutAssetId, maxApproval));
    }

    function hub_createAccount(uint32 accountAsInt, bool isDebitNormal) public {
        AccountId account = AccountId.wrap(accountAsInt);
        queuedCalls.push(abi.encodeWithSelector(hub.createAccount.selector, account, isDebitNormal));
    }

    function hub_createHolding(bytes16 scIdAsBytes, uint128 assetIdAsUint, IERC7726 valuation, bool isLiability, uint24 prefix) public {
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        queuedCalls.push(abi.encodeWithSelector(hub.createHolding.selector, scId, assetId, valuation, isLiability, prefix));
    }

    function hub_issueShares(bytes16 scIdAsBytes, uint128 depositAssetIdAsUint, D18 navPerShare) public {
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId depositAssetId = AssetId.wrap(depositAssetIdAsUint);
        queuedCalls.push(abi.encodeWithSelector(hub.issueShares.selector, scId, depositAssetId, navPerShare));
    }

    function hub_notifyPool(uint32 chainId) public {
        queuedCalls.push(abi.encodeWithSelector(hub.notifyPool.selector, chainId));
    }

    function hub_notifyShareClass(uint32 chainId, bytes16 scIdAsBytes, bytes32 hook) public {
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        queuedCalls.push(abi.encodeWithSelector(hub.notifyShareClass.selector, chainId, scId, hook));
    }

    function hub_revokeShares(bytes16 scIdAsBytes, uint32 isoCode, D18 navPerShare, IERC7726 valuation) public {
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId payoutAssetId = newAssetId(isoCode);

        queuedCalls.push(abi.encodeWithSelector(hub.revokeShares.selector, scId, payoutAssetId, navPerShare, valuation));
    }

    function hub_setAccountMetadata(uint32 accountAsInt, bytes memory metadata) public {
        AccountId account = AccountId.wrap(accountAsInt);
        queuedCalls.push(abi.encodeWithSelector(hub.setAccountMetadata.selector, account, metadata));
    }

    function hub_setHoldingAccountId(bytes16 scIdAsBytes, uint128 assetIdAsUint, uint32 accountIdAsInt) public {
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        AccountId accountId = AccountId.wrap(accountIdAsInt);
        queuedCalls.push(abi.encodeWithSelector(hub.setHoldingAccountId.selector, scId, assetId, accountId));
    }

    function hub_setPoolMetadata(bytes memory metadata) public {
        queuedCalls.push(abi.encodeWithSelector(hub.setPoolMetadata.selector, metadata));
    }

    function hub_updateHolding(bytes16 scIdAsBytes, uint128 assetIdAsUint) public {
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        queuedCalls.push(abi.encodeWithSelector(hub.updateHolding.selector, scId, assetId));

        // state space enrichment to help get coverage over this function
        if(poolCreated && deposited) { 
            emit LogString("poolCreated && deposited should allow updateHolding");
        }
    }

    function hub_updateHoldingValuation(bytes16 scIdAsBytes, uint128 assetIdAsUint, IERC7726 valuation) public {
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        queuedCalls.push(abi.encodeWithSelector(hub.updateHoldingValuation.selector, scId, assetId, valuation));
    }

    function hub_updateRestriction(uint16 chainId, bytes16 scIdAsBytes, bytes calldata payload) public {
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        queuedCalls.push(abi.encodeWithSelector(hub.updateRestriction.selector, chainId, scId, payload));
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
    function hub_depositRequest(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint32 isoCode, uint128 amount) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId depositAssetId = newAssetId(isoCode);
        bytes32 investor = Helpers.addressToBytes32(_getActor());

        try hub.depositRequest(poolId, scId, investor, depositAssetId, amount) {
            deposited = true;

            (, uint32 lastUpdate) = shareClassManager.depositRequest(scId, depositAssetId, investor);
            uint32 epochId = shareClassManager.epochId(poolId);

            eq(lastUpdate, epochId, "lastUpdate is not equal to epochId"); 

            address[] memory _actors = _getActors();
            uint128 totalPendingDeposit = shareClassManager.pendingDeposit(scId, depositAssetId);
            uint128 totalPendingUserDeposit = 0;
            for (uint256 k = 0; k < _actors.length; k++) {
                address actor = _actors[k];
                (uint128 pendingUserDeposit,) = shareClassManager.depositRequest(scId, depositAssetId, Helpers.addressToBytes32(actor));
                totalPendingUserDeposit += pendingUserDeposit;
            }

            gte(totalPendingDeposit, totalPendingUserDeposit, "total pending deposit is less than sum of pending user deposit amounts"); 
        } catch (bytes memory reason) {
            bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
            t(!arithmeticRevert, "depositRequest reverts with arithmetic panic");
        }  
    }   

    /// @dev Property: After successfully calling redeemRequest for an investor, their redeemRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: _updateRedeemRequest should never revert due to underflow
    function hub_redeemRequest(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint32 isoCode, uint128 amount) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId payoutAssetId = newAssetId(isoCode);
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

        try hub.cancelDepositRequest(poolId, scId, investor, depositAssetId) {
            (uint128 pending, uint32 lastUpdate) = shareClassManager.depositRequest(scId, depositAssetId, investor);
            uint32 epochId = shareClassManager.epochId(poolId);

            console2.log("here");
            eq(lastUpdate, epochId, "lastUpdate is not equal to current epochId");
            eq(pending, 0, "pending is not zero");
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

    function hub_updateHoldingAmount(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint128 amount, D18 pricePerUnit, bool isIncrease, JournalEntry[] memory debits, JournalEntry[] memory credits) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.updateHoldingAmount(poolId, scId, assetId, amount, pricePerUnit, isIncrease, debits, credits);
    }

    function hub_updateHoldingValue(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, D18 pricePerUnit) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.updateHoldingValue(poolId, scId, assetId, pricePerUnit);
    }

    function hub_updateJournal(uint64 poolIdAsUint, JournalEntry[] memory debits, JournalEntry[] memory credits) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        hub.updateJournal(poolId, debits, credits);
    }

    function hub_increaseShareIssuance(uint64 poolIdAsUint, bytes16 scIdAsBytes, D18 pricePerShare, uint128 amount) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.increaseShareIssuance(poolId, scId, pricePerShare, amount);
    }

    function hub_increaseShareIssuance_clamped(uint64 poolEntropy, uint32 scEntropy, D18 pricePerShare, uint128 amount) public updateGhosts {
        PoolId poolId = _getRandomPoolId(poolEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        hub.increaseShareIssuance(poolId, scId, pricePerShare, amount);
    }

    function hub_decreaseShareIssuance(uint64 poolIdAsUint, bytes16 scIdAsBytes, D18 pricePerShare, uint128 amount) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        hub.decreaseShareIssuance(poolId, scId, pricePerShare, amount);
    }

    function hub_decreaseShareIssuance_clamped(uint64 poolEntropy, uint32 scEntropy, D18 pricePerShare, uint128 amount) public updateGhosts {
        PoolId poolId = _getRandomPoolId(poolEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scEntropy);
        hub.decreaseShareIssuance(poolId, scId, pricePerShare, amount);
    }

    // === PoolRouter === //

    function hub_execute(uint64 poolIdAsUint, bytes[] memory data) public payable updateGhostsWithType(OpType.BATCH) asAdmin {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        hub.execute{value: msg.value}(poolId, data);
    }

    /// @dev Makes a call directly to the unclamped handler so doesn't include asAdmin modifier or else would cause errors with foundry testing
    function hub_execute_clamped(uint64 poolIdAsUint) public payable {
        // TODO: clamp poolId here to one of the created pools
        this.hub_execute{value: msg.value}(poolIdAsUint, queuedCalls);

        queuedCalls = new bytes[](0);
    }

    // === MultiShareClass === //

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

    function shareClassManager_issueSharesUntilEpoch(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, D18 navPerShare, uint32 endEpochId) public updateGhosts asAdmin {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId shareClassId_ = ShareClassId.wrap(scIdAsBytes);
        AssetId depositAssetId = AssetId.wrap(assetIdAsUint);
        shareClassManager.issueSharesUntilEpoch(poolId, shareClassId_, depositAssetId, navPerShare, endEpochId);
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