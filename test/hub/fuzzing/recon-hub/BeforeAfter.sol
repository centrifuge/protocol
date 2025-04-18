// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Interfaces
import {EpochPointers, UserOrder} from "src/hub/interfaces/IShareClassManager.sol";
import {AccountId} from "src/hub/interfaces/IAccounting.sol";
import {IAccounting} from "src/hub/interfaces/IAccounting.sol";

// Types
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

// Recon Utils
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";
import {BaseBeforeAfter} from "./BaseBeforeAfter.sol";
import {Properties} from "./Properties.sol";

// This actually makes the changes to the tracking variables defined in BaseBeforeAfter
abstract contract BeforeAfter is Properties {
    function __before() internal override {
        _before.ghostDebited = accounting.debited();
        _before.ghostCredited = accounting.credited();
        
        for (uint256 i = 0; i < createdPools.length; i++) {
            address[] memory _actors = _getActors();
            PoolId poolId = createdPools[i];
            _before.ghostEpochId[poolId] = shareClassManager.epochId(poolId);
            // loop through all share classes for the pool
            for (uint32 j = 0; j < shareClassManager.shareClassCount(poolId); j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                (,_before.ghostLatestRedeemApproval,,) = shareClassManager.epochPointers(scId, assetId);
                (, _before.ghostHolding[poolId][scId][assetId],,) = holdings.holding(poolId, scId, assetId);
                // loop over all actors
                for (uint256 k = 0; k < _actors.length; k++) {
                    bytes32 actor = Helpers.addressToBytes32(_actors[k]);
                    (uint128 pendingRedeem, uint32 lastUpdate) = shareClassManager.redeemRequest(scId, assetId, actor);
                    _before.ghostRedeemRequest[scId][assetId][actor] = UserOrder({pending: pendingRedeem, lastUpdate: lastUpdate});
                }

                // loop over all account types defined in IHub::AccountType
                for(uint8 kind = 0; kind < 6; kind++) {
                    AccountId accountId = holdings.accountId(poolId, scId, assetId, kind);
                    (,,,uint64 lastUpdated,) = accounting.accounts(poolId, accountId);
                    // accountValue is only set if the account has been updated
                    if(lastUpdated != 0) {
                        _before.ghostAccountValue[poolId][accountId] = accounting.accountValue(poolId, accountId);
                    }
                }
            }
        }
    }

    function __after() internal override {
        _after.ghostDebited = accounting.debited();
        _after.ghostCredited = accounting.credited();
        
        for (uint256 i = 0; i < createdPools.length; i++) {
            address[] memory _actors = _getActors();
            PoolId poolId = createdPools[i];
            _after.ghostEpochId[poolId] = shareClassManager.epochId(poolId);
            // loop through all share classes for the pool
            for (uint32 j = 0; j < shareClassManager.shareClassCount(poolId); j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);
                
                (,_after.ghostLatestRedeemApproval,,) = shareClassManager.epochPointers(scId, assetId);
                (, _after.ghostHolding[poolId][scId][assetId],,) = holdings.holding(poolId, scId, assetId);
                // loop over all actors
                for (uint256 k = 0; k < _actors.length; k++) {
                    bytes32 actor = Helpers.addressToBytes32(_actors[k]);
                    (uint128 pendingRedeem, uint32 lastUpdate) = shareClassManager.redeemRequest(scId, assetId, actor);
                    _after.ghostRedeemRequest[scId][assetId][actor] = UserOrder({pending: pendingRedeem, lastUpdate: lastUpdate});
                }

                // loop over all account types defined in IHub::AccountType
                for(uint8 kind = 0; kind < 6; kind++) {
                    AccountId accountId = holdings.accountId(poolId, scId, assetId, kind);
                    (,,,uint64 lastUpdated,) = accounting.accounts(poolId, accountId);
                    // accountValue is only set if the account has been updated
                    if(lastUpdated != 0) {
                        _after.ghostAccountValue[poolId][accountId] = accounting.accountValue(poolId, accountId);
                    }
                }
            }
        }
    }
}