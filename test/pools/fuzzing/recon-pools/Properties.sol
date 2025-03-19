// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {Asserts} from "@chimera/Asserts.sol";

import {AssetId} from "src/pools/types/AssetId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";

import {Helpers} from "test/pools/fuzzing/recon-pools/utils/Helpers.sol";
import {BeforeAfter} from "./BeforeAfter.sol";

abstract contract Properties is BeforeAfter, Asserts {
    using MathLib for D18;

    /// === Canaries === ///
    function canary_cancelledRedeemRequest() public {
        t(!cancelledRedeemRequest, "successfully cancelled redeem request");
    }

    /// === Global Properties === ///
    function property_unlockedPoolId_transient_reset() public {
        eq(_after.ghostUnlockedPoolId.raw(), 0, "unlockedPoolId not reset");
    }

    function property_debited_transient_reset() public {
        eq(_after.ghostDebited, 0, "debited not reset");
    }

    function property_credited_transient_reset() public {
        eq(_after.ghostCredited, 0, "credited not reset");
    }

    function property_cancelled_redemption_never_greater_than_requested() public {
        address[] memory _actors = _getActors();

        // loop through all created pools
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = multiShareClass.shareClassCount(poolId);
            
            // loop through all share classes in the pool
            for (uint32 j = 0; j < shareClassCount; j++) {
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