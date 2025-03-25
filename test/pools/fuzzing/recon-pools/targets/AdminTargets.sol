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
import {AccountId} from "src/pools/types/AccountId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {BeforeAfter, OpType} from "../BeforeAfter.sol";
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

    function poolRouter_approveRedeems(ShareClassId scId, uint32 isoCode, uint128 maxApproval) public {
        AssetId payoutAssetId = newAssetId(isoCode);
        
        queuedCalls.push(abi.encodeWithSelector(poolRouter.approveRedeems.selector, scId, payoutAssetId, maxApproval));
    }

    function poolRouter_createAccount(AccountId account, bool isDebitNormal) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.createAccount.selector, account, isDebitNormal));
    }

    function poolRouter_createHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint24 prefix) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.createHolding.selector, scId, assetId, valuation, prefix));
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

    function poolRouter_revokeShares(ShareClassId scId, uint32 isoCode, D18 navPerShare, IERC7726 valuation) public {
        AssetId payoutAssetId = newAssetId(isoCode);

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

        // state space enrichment to help get coverage over this function
        if(poolCreated && deposited) { 
            emit LogString("poolCreated && deposited should allow updateHolding");
        }
    }

    function poolRouter_updateHoldingValuation(ShareClassId scId, AssetId assetId, IERC7726 valuation) public {
        queuedCalls.push(abi.encodeWithSelector(poolRouter.updateHoldingValuation.selector, scId, assetId, valuation));
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    // === PoolManager === //
    /// Gateway owner methods: these get called directly because we're not using the gateway in our setup

    function poolRouter_registerAsset(uint32 isoCode) public updateGhosts asAdmin {
        AssetId assetId_ = newAssetId(isoCode); 

        string memory name = MockERC20(_getAsset()).name();
        string memory symbol = MockERC20(_getAsset()).symbol();
        uint8 decimals = MockERC20(_getAsset()).decimals();

        poolRouter.registerAsset(assetId_, name, symbol, decimals);
    }  

    /// @dev Property: after successfully calling requestDeposit for an investor, their depositRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: _updateDepositRequest should never revert due to underflow
    /// @dev Property: The total pending deposit amount pendingDeposit[..] is always >= the sum of pending user deposit amounts depositRequest[..]
    function poolRouter_depositRequest(PoolId poolId, ShareClassId scId, uint32 isoCode, uint128 amount) public updateGhosts asAdmin {
        AssetId depositAssetId = newAssetId(isoCode);
        bytes32 investor = Helpers.addressToBytes32(_getActor());

        try poolRouter.depositRequest(poolId, scId, investor, depositAssetId, amount) {
            deposited = true;

            (, uint32 lastUpdate) = multiShareClass.depositRequest(scId, depositAssetId, investor);
            uint32 epochId = multiShareClass.epochId(poolId);

            eq(lastUpdate, epochId, "lastUpdate is not equal to epochId"); 

            address[] memory _actors = _getActors();
            uint128 totalPendingDeposit = multiShareClass.pendingDeposit(scId, depositAssetId);
            uint128 totalPendingUserDeposit = 0;
            for (uint256 k = 0; k < _actors.length; k++) {
                address actor = _actors[k];
                (uint128 pendingUserDeposit,) = multiShareClass.depositRequest(scId, depositAssetId, Helpers.addressToBytes32(actor));
                totalPendingUserDeposit += pendingUserDeposit;
            }

            gte(totalPendingDeposit, totalPendingUserDeposit, "total pending deposit is less than sum of pending user deposit amounts"); 
        } catch (bytes memory reason) {
            bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
            t(!arithmeticRevert, "depositRequest reverts with arithmetic panic");
        }  
    }   

    /// @dev Property: After successfully calling redeemRequest for an investor, their redeemRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: _updateRedeemRequest should never revert due to underflow
    function poolRouter_redeemRequest(PoolId poolId, ShareClassId scId, uint32 isoCode, uint128 amount) public updateGhosts asAdmin {
        AssetId payoutAssetId = newAssetId(isoCode);
        bytes32 investor = Helpers.addressToBytes32(_getActor());

        try poolRouter.redeemRequest(poolId, scId, investor, payoutAssetId, amount) {
            (, uint32 lastUpdate) = multiShareClass.redeemRequest(scId, payoutAssetId, investor);
            uint32 epochId = multiShareClass.epochId(poolId);

            eq(lastUpdate, epochId, "lastUpdate is not equal to epochId after redeemRequest");
        } catch (bytes memory reason) {
            bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
            t(!arithmeticRevert, "redeemRequest reverts with arithmetic panic");
        }
    }  

    /// @dev The investor is explicitly clamped to one of the actors to make checking properties over all actors easier 
    /// @dev Property: after successfully calling cancelDepositRequest for an investor, their depositRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: after successfully calling cancelDepositRequest for an investor, their depositRequest[..].pending is zero
    /// @dev Property: cancelDepositRequest absolute value should never be higher than pendingDeposit (would result in underflow revert)
    /// @dev Property: _updateDepositRequest should never revert due to underflow
    /// @dev Property: The total pending deposit amount pendingDeposit[..] is always >= the sum of pending user deposit amounts depositRequest[..]
    function poolRouter_cancelDepositRequest(PoolId poolId, ShareClassId scId, uint32 isoCode) public updateGhosts asAdmin {
        AssetId depositAssetId = newAssetId(isoCode);
        bytes32 investor = Helpers.addressToBytes32(_getActor());

        try poolRouter.cancelDepositRequest(poolId, scId, investor, depositAssetId) {
            (uint128 pending, uint32 lastUpdate) = multiShareClass.depositRequest(scId, depositAssetId, investor);
            uint32 epochId = multiShareClass.epochId(poolId);

            eq(lastUpdate, epochId, "lastUpdate is not equal to current epochId");
            eq(pending, 0, "pending is not zero");
        } catch (bytes memory reason) {
            bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
            t(!arithmeticRevert, "cancelDepositRequest reverts with arithmetic panic");
        }
    }

    /// @dev Property: After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].pending is zero
    /// @dev Property: cancelRedeemRequest absolute value should never be higher than pendingRedeem (would result in underflow revert)
    function poolRouter_cancelRedeemRequest(PoolId poolId, ShareClassId scId, uint32 isoCode) public updateGhosts asAdmin {
        AssetId payoutAssetId = newAssetId(isoCode);
        bytes32 investor = Helpers.addressToBytes32(_getActor());

        poolRouter.cancelRedeemRequest(poolId, scId, investor, payoutAssetId);

        try poolRouter.cancelRedeemRequest(poolId, scId, investor, payoutAssetId) {
            (uint128 pending, uint32 lastUpdate) = multiShareClass.redeemRequest(scId, payoutAssetId, investor);
            uint32 epochId = multiShareClass.epochId(poolId);

            eq(lastUpdate, epochId, "lastUpdate is not equal to current epochId after cancelRedeemRequest");
            eq(pending, 0, "pending is not zero after cancelRedeemRequest");
        } catch (bytes memory reason) {
            bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
            t(!arithmeticRevert, "cancelRedeemRequest reverts with arithmetic panic");
        }
    }

    // === PoolRouter === //

    function poolRouter_execute(PoolId poolId, bytes[] memory data) public payable updateGhostsWithType(OpType.BATCH) asAdmin {
        poolRouter.execute{value: msg.value}(poolId, data);
    }

    /// @dev Makes a call directly to the unclamped handler so doesn't include asAdmin modifier or else would cause errors with foundry testing
    function poolRouter_execute_clamped(PoolId poolId) public payable {
        // TODO: clamp poolId here to one of the created pools
        this.poolRouter_execute{value: msg.value}(poolId, queuedCalls);

        queuedCalls = new bytes[](0);
    }

    // === MultiShareClass === //

    function multiShareClass_claimDepositUntilEpoch(PoolId poolId, ShareClassId shareClassId_, AssetId depositAssetId, uint32 endEpochId) public updateGhosts asAdmin {
        bytes32 investor = Helpers.addressToBytes32(_getActor());

        multiShareClass.claimDepositUntilEpoch(poolId, shareClassId_, investor, depositAssetId, endEpochId);
    }

    function multiShareClass_claimRedeemUntilEpoch(PoolId poolId, ShareClassId shareClassId_, bytes32 investor, AssetId payoutAssetId, uint32 endEpochId) public updateGhosts asAdmin {
        multiShareClass.claimRedeemUntilEpoch(poolId, shareClassId_, investor, payoutAssetId, endEpochId);
    }

    function multiShareClass_issueSharesUntilEpoch(PoolId poolId, ShareClassId shareClassId_, AssetId depositAssetId, D18 navPerShare, uint32 endEpochId) public updateGhosts asAdmin {
        multiShareClass.issueSharesUntilEpoch(poolId, shareClassId_, depositAssetId, navPerShare, endEpochId);
    }

    function multiShareClass_revokeSharesUntilEpoch(PoolId poolId, ShareClassId shareClassId_, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation, uint32 endEpochId) public updateGhosts asAdmin {
        multiShareClass.revokeSharesUntilEpoch(poolId, shareClassId_, payoutAssetId, navPerShare, valuation, endEpochId);
    }

    function multiShareClass_updateMetadata(PoolId poolId, ShareClassId shareClassId_, string memory name, string memory symbol, bytes32 salt, bytes memory data) public updateGhosts asActor {
        multiShareClass.updateMetadata(PoolId(poolId), ShareClassId(shareClassId_), name, symbol, salt, data);
    }
}