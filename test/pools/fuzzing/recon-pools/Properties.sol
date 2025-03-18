// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {Asserts} from "@chimera/Asserts.sol";

import {AssetId} from "src/pools/types/AssetId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";

import {Helpers} from "test/recon/utils/Helpers.sol";
import {BeforeAfter} from "./BeforeAfter.sol";

abstract contract Properties is BeforeAfter, Asserts {
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
                ShareClassId scId = multiShareClass.indexToScId(poolId, j);
                AssetId assetId = poolRegistry.currency(poolId);

                // loop through all actors
                for (uint256 k = 0; k < _actors.length; k++) {
                    address actor = _actors[k];
                    (uint128 pendingUserRedemption,) = multiShareClass.redeemRequest(scId, assetId, Helpers.addressToBytes32(actor));
                    // check if the actor has a redeem request
                    gte(
                        multiShareClass.pendingRedeem(scId, assetId), 
                        pendingUserRedemption, 
                        "cancelled redemption is greater than requested redemption"
                        );
                }
            }
        }
    }
}