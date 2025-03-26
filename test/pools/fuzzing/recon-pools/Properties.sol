// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {Asserts} from "@chimera/Asserts.sol";

import {AssetId} from "src/pools/types/AssetId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";

import {Helpers} from "test/pools/fuzzing/recon-pools/utils/Helpers.sol";
import {BeforeAfter, OpType} from "./BeforeAfter.sol";

import {console2} from "forge-std/console2.sol";

abstract contract Properties is BeforeAfter, Asserts {
    using MathLib for D18;

    /// === Canaries === ///

    /// === Global Properties === ///

    function property_unlockedPoolId_transient_reset() public {
        eq(_after.ghostUnlockedPoolId.raw(), 0, "unlockedPoolId not reset");
    }

    // NOTE: these are commented out because they don't actually get reset after calls, only when there's a call to unlock or a new tx
    // function property_debited_transient_reset() public {
    //     eq(_after.ghostDebited, 0, "debited not reset");
    // }

    // function property_credited_transient_reset() public {
    //     eq(_after.ghostCredited, 0, "credited not reset");
    // }

    /// @dev Property: User pending redemption is never greater than the total redemption
    function property_pending_user_redemption_never_greater_than_total_redemption() public {
        address[] memory _actors = _getActors();

        // loop through all created pools
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = multiShareClass.shareClassCount(poolId);
            
            // loop through all share classes in the pool
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = multiShareClass.previewShareClassId(poolId, j);
                AssetId assetId = poolRegistry.currency(poolId);

                // loop through all actors
                for (uint256 k = 0; k < _actors.length; k++) {
                    address actor = _actors[k];
                    (uint128 pendingUserRedemption,) = multiShareClass.redeemRequest(scId, assetId, Helpers.addressToBytes32(actor));
                    // check if the actor has a redeem request
                    gte(
                        multiShareClass.pendingRedeem(scId, assetId), 
                        pendingUserRedemption, 
                        "user redemption is greater than total redemption"
                        );
                }
            }
        }
    }

    /// @dev Property: The total pending asset amount pendingDeposit[..] is always >= than the approved asset amount epochAmounts[..].depositApproved
    function property_total_pending_and_approved() public {
        address[] memory _actors = _getActors();

        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = multiShareClass.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = multiShareClass.previewShareClassId(poolId, j);
                AssetId assetId = poolRegistry.currency(poolId);

                uint32 epochId = multiShareClass.epochId(poolId);
                uint128 pendingDeposit = multiShareClass.pendingDeposit(scId, assetId);
                (uint128 depositPending, uint128 approvedDeposit,,,,,) = multiShareClass.epochAmounts(scId, assetId, epochId);

                gte(pendingDeposit, approvedDeposit, "pending deposit is less than approved deposit");
                gte(pendingDeposit, depositPending, "pending deposit is less than pending for epoch");
            }
        }
    }

    /// @dev Property: The total pending redeem amount pendingRedeem[..] is always geq the sum of pending user redeem amounts redeemRequest[..]
    /// @dev Property: The total pending redeem amount pendingRedeem[..] is always geq than the approved redeem amount epochAmounts[..].redeemRevokedShares
    function property_total_pending_redeem_geq_sum_pending_user_redeem() public {
        address[] memory _actors = _getActors();

        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = multiShareClass.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = multiShareClass.previewShareClassId(poolId, j);
                AssetId assetId = poolRegistry.currency(poolId);

                uint32 epochId = multiShareClass.epochId(poolId);
                uint128 pendingRedeem = multiShareClass.pendingRedeem(scId, assetId);
                (,,,,, uint128 redeemApproved,) = multiShareClass.epochAmounts(scId, assetId, epochId);

                uint128 totalPendingUserRedeem = 0;
                for (uint256 k = 0; k < _actors.length; k++) {
                    address actor = _actors[k];
                    (uint128 pendingUserRedeem,) = multiShareClass.redeemRequest(scId, assetId, Helpers.addressToBytes32(actor));
                    totalPendingUserRedeem += pendingUserRedeem;
                }

                // check that the pending redeem is >= the total pending user redeem
                gte(pendingRedeem, totalPendingUserRedeem, "pending redeem is < total pending user redeems");
                // check that the pending redeem is >= the approved redeem
                gte(pendingRedeem, redeemApproved, "pending redeem is < approved redeem");
            }
        }
    }

    /// @dev Property: The current pool epochId is always strictly greater than any latest pointer of epochPointers[...]
    function property_epochId_strictly_greater_than_any_latest_pointer() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 epochId = multiShareClass.epochId(poolId);

            uint32 shareClassCount = multiShareClass.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = multiShareClass.previewShareClassId(poolId, j);
                AssetId assetId = poolRegistry.currency(poolId);

                (uint32 latestDepositApproval, uint32 latestRedeemApproval, uint32 latestIssuance, uint32 latestRevocation) = multiShareClass.epochPointers(scId, assetId);
                
                gt(epochId, latestDepositApproval, "epochId is not strictly greater than latest deposit approval");
                gt(epochId, latestRedeemApproval, "epochId is not strictly greater than latest redeem approval");
                gt(epochId, latestIssuance, "epochId is not strictly greater than latest issuance");
                gt(epochId, latestRevocation, "epochId is not strictly greater than latest revocation");
            }
            
        }
    }

    /// @dev Property: The epoch of a pool epochId[poolId] can increase at most by one within the same transaction (i.e. multicall/execute) independent of the number of approvals
    function property_epochId_can_increase_by_one_within_same_transaction() public {
        // precondition: there must've been a batch operation (call to execute/multicall)
        if(currentOperation == OpType.BATCH) {
            for (uint256 i = 0; i < createdPools.length; i++) {
                PoolId poolId = createdPools[i];

                uint32 epochIdDifference = _after.ghostEpochId[poolId] - _before.ghostEpochId[poolId];
                // check that the epochId increased by at most 1
                lte(epochIdDifference, 1, "epochId increased by more than 1");
            }
        }
    }

    /// @dev Property: After FM performs approveDeposits and revokeShares with non-zero navPerShare, the total issuance totalIssuance[..] is increased
    /// @dev WIP, this may not be possible to prove because these calls are made via execute which makes determining the before and after state difficult
    // function property_total_issuance_increased_after_approve_deposits_and_revoke_shares() public {
        
    //     bool hasApprovedDeposits = false;
    //     bool hasRevokedShares = false;
    //     for(uint256 i = 0; i < queuedOps.length; i++) {
    //         QueuedOp queuedOp = queuedOps[i];
    //         if(queuedOp.op == Op.APPROVE_DEPOSITS) {
    //             hasApprovedDeposits = true;
    //         }

    //         // there has to have been an approveDeposits call before a revokeShares call
    //         if(queuedOp.op == Op.REVOKE_SHARES && hasApprovedDeposits) {
    //             hasRevokedShares = true;
    //         }
    //     }

    //     // if(hasApprovedDeposits && hasRevokedShares) {
    //     //     multiShareClass.metrics(scId);
    //     // }
    // }
    /// Stateless Properties ///

    /// @dev Property: The sum of eligible user payoutShareAmount for an epoch is <= the number of issued shares epochAmounts[..].depositShares
    /// @dev Property: The sum of eligible user payoutAssetAmount for an epoch is <= the number of issued asset amount epochAmounts[..].depositPool
    /// @dev Stateless because of the calls to claimDeposit which would make story difficult to read
    function property_eligible_user_deposit_amount_leq_deposit_issued_amount() public stateless {
        address[] memory _actors = _getActors();

        // loop over all created pools
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = multiShareClass.shareClassCount(poolId);
            
            // check that the epoch has ended, if not, skip
            // we know an epoch has ended if the epochId changed after an operation which we cache in the before/after structs
            if (_before.ghostEpochId[poolId] == _after.ghostEpochId[poolId]) {
                continue;
            }

            // loop over all share classes in the pool
            uint128 totalPayoutShareAmount = 0;
            uint128 totalPayoutAssetAmount = 0;
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = multiShareClass.previewShareClassId(poolId, j);
                AssetId assetId = poolRegistry.currency(poolId);

                // check the previous epochId since the current epoch is still ongoing
                uint32 epochId = multiShareClass.epochId(poolId) - 1;
                (,, uint128 depositPoolApproved, uint128 depositSharesIssued,,,) = multiShareClass.epochAmounts(scId, assetId, epochId);

                // loop over all actors
                for (uint256 k = 0; k < _actors.length; k++) {
                    address actor = _actors[k];
                    
                    // we claim via multiShareClass directly here because PoolRouter doesn't return the payoutShareAmount
                    (uint128 payoutShareAmount, uint128 payoutAssetAmount) = multiShareClass.claimDeposit(poolId, scId, Helpers.addressToBytes32(actor), assetId);
                    totalPayoutShareAmount += payoutShareAmount;
                    totalPayoutAssetAmount += payoutAssetAmount;
                }

                // check that the totalPayoutShareAmount is less than or equal to the depositSharesIssued
                lte(totalPayoutShareAmount, depositSharesIssued, "totalPayoutShareAmount is greater than issued shares");
                // check that the totalPayoutAssetAmount is less than or equal to the depositPoolApproved
                lte(totalPayoutAssetAmount, depositPoolApproved, "totalPayoutAssetAmount is greater than depositPoolApproved");

                uint128 differenceShares = depositSharesIssued - totalPayoutShareAmount;
                uint128 differenceAsset = depositPoolApproved - totalPayoutAssetAmount;
                // check that the totalPayoutShareAmount is no more than 1 wei less than the depositSharesIssued
                lte(differenceShares, 1, "depositSharesIssued - totalPayoutShareAmount difference is greater than 1");
                // check that the totalPayoutAssetAmount is no more than 1 wei less than the depositAssetAmount
                lte(differenceAsset, 1, "depositAssetAmount - totalPayoutAssetAmount difference is greater than 1");
            }
        }
            
    }

    /// @dev Property: The sum of eligible user claim payout asset amounts for an epoch is <= the approved asset amount epochAmounts[..].redeemApproved
    /// @dev Property: The sum of eligible user claim payment share amounts for an epoch is <= than the revoked share amount epochAmounts[..].redeemAssets
    /// @dev This doesn't sum over previous epochs because it can be assumed that it'll be called by the fuzzer for each current epoch
    function property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount() public stateless {
        address[] memory _actors = _getActors();

        // loop over all created pools
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = multiShareClass.shareClassCount(poolId);
            // loop over all share classes in the pool
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = multiShareClass.previewShareClassId(poolId, j);
                AssetId assetId = poolRegistry.currency(poolId);

                uint32 epochId = multiShareClass.epochId(poolId);
                (,,,,, uint128 redeemApprovedShares, uint128 redeemAssets) = multiShareClass.epochAmounts(scId, assetId, epochId);

                // sum eligible user claim payoutAssetAmount for the epoch
                uint128 totalPayoutAssetAmount = 0;
                uint128 totalPaymentShareAmount = 0;
                for (uint256 k = 0; k < _actors.length; k++) {
                    address actor = _actors[k];
                    // we claim via multiShareClass directly here because PoolRouter doesn't return the payoutAssetAmount
                    (uint128 payoutAssetAmount, uint128 paymentShareAmount) = multiShareClass.claimRedeem(poolId, scId, Helpers.addressToBytes32(actor), assetId);
                    totalPayoutAssetAmount += payoutAssetAmount;
                    totalPaymentShareAmount += paymentShareAmount;
                }

                // check that the totalPayoutAssetAmount is less than or equal to the redeemApproved
                lte(totalPayoutAssetAmount, redeemAssets, "total payout asset amount is > redeem assets");
                // check that the totalPaymentShareAmount is less than or equal to the redeemApproved
                lte(totalPaymentShareAmount, redeemApprovedShares, "total payment share amount is > redeem shares revoked");

                uint128 differenceAsset = redeemAssets - totalPayoutAssetAmount;
                uint128 differenceShare = redeemApprovedShares - totalPaymentShareAmount;
                // check that the totalPayoutAssetAmount is no more than 1 wei less than the redeemAssets
                lte(differenceAsset, 1, "redeemAssets - totalPayoutAssetAmount difference is greater than 1");
                // check that the totalPaymentShareAmount is no more than 1 wei less than the redeemApproved
                lte(differenceShare, 1, "redeemApprovedShares - totalPaymentShareAmount difference is greater than 1");
            }
        }
    }

    /// @dev Property: A user cannot mutate their pending redeem amount pendingRedeem[...] if the pendingRedeem[..].lastUpdate is <= the latest redeem approval pointer epochPointers[..].latestRedeemApproval
    function property_user_cannot_mutate_pending_redeem() public stateless {
        address[] memory _actors = _getActors();

        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = multiShareClass.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = multiShareClass.previewShareClassId(poolId, j);
                AssetId assetId = poolRegistry.currency(poolId);

                // loop over all actors
                for (uint256 k = 0; k < _actors.length; k++) {
                    bytes32 actor = Helpers.addressToBytes32(_actors[k]);
                    // precondition: pending has changed 
                    if (_before.ghostRedeemRequest[scId][assetId][actor].pending == _after.ghostRedeemRequest[scId][assetId][actor].pending) {
                        continue;
                    }

                    // check that the lastUpdate was > the latest redeem approval pointer
                    gt(_before.ghostRedeemRequest[scId][assetId][actor].lastUpdate, _before.ghostLatestRedeemApproval, "lastUpdate is > latest redeem approval");
                }
            }
        }
    }

    /// Rounding Properties /// 

    /// @dev Property: Checks that rounding error is within acceptable bounds (1000 wei)
    /// @dev Simulates the operation in the MultiShareClass::_revokeEpochShares function
    function property_MulUint128Rounding(D18 navPerShare, uint128 amount) public {
        // Bound navPerShare up to 1,000,000
        uint128 innerValue = D18.unwrap(navPerShare) % uint128(1e24);
        navPerShare = d18(innerValue); 
        
        // Calculate result using mulUint128
        uint128 result = navPerShare.mulUint128(amount);
        
        // Calculate expected result with higher precision
        uint256 expectedResult = MathLib.mulDiv(D18.unwrap(navPerShare), amount, 1e18);
        
        // Check if downcasting caused any loss
        lte(result, expectedResult, "Result should not be greater than expected");
        
        // Check if rounding error is within acceptable bounds (1000 wei)
        uint256 roundingError = expectedResult - result;
        lte(roundingError, 1000, "Rounding error too large");
        
        // Verify reverse calculation approximately matches
        // if (result > 0) {
        //     D18 reverseNav = D18.wrap((uint256(result) * 1e18) / amount);
        //     uint256 navDiff = D18.unwrap(navPerShare) >= D18.unwrap(reverseNav) 
        //         ? D18.unwrap(navPerShare) - D18.unwrap(reverseNav)
        //         : D18.unwrap(reverseNav) - D18.unwrap(navPerShare);
                
        //     // Allow for some small difference due to division rounding
        //     lte(navDiff, 1e6, "Reverse calculation deviation too large"); 
        // }
    }

    /// @dev Property: Checks that rounding error is within acceptable bounds (1e6 wei) for very small numbers
    /// @dev Simulates the operation in the MultiShareClass::_revokeEpochShares function
    function property_MulUint128EdgeCases(D18 navPerShare, uint128 amount) public {
        // Test with very small numbers
        amount = uint128(amount % 1000);  // Small amounts
        navPerShare = D18.wrap(D18.unwrap(navPerShare) % 1e9);  // Small NAV
        
        uint128 result = navPerShare.mulUint128(amount);
        
        // Even with very small numbers, result should be proportional
        if (result > 0) {
            uint256 ratio = (uint256(amount) * 1e18) / result;
            uint256 expectedRatio = 1e18 / uint256(D18.unwrap(navPerShare));
            
            // Allow for some rounding difference
            uint256 ratioDiff = ratio >= expectedRatio ? ratio - expectedRatio : expectedRatio - ratio;
            lte(ratioDiff, 1e6, "Ratio deviation too large for small numbers");
        }
    }
}