// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {EpochPointers, UserOrder} from "src/pools/MultiShareClass.sol";
import {Helpers} from "test/pools/fuzzing/recon-pools/utils/Helpers.sol";
import {Setup} from "./Setup.sol";

enum OpType {
    GENERIC,
    DEPOSIT,
    REDEEM,
    BATCH // batch operations that make multiple calls in one transaction
}

// ghost variables for tracking state variable values before and after function calls
abstract contract BeforeAfter is Setup {
    struct Vars {
        PoolId ghostUnlockedPoolId;
        uint128 ghostDebited;
        uint128 ghostCredited;
        uint32 ghostLatestRedeemApproval;
        mapping(PoolId poolId => uint32) ghostEpochId;
        mapping(ShareClassId scId => mapping(AssetId payoutAssetId => mapping(bytes32 investor => UserOrder pending)))
            ghostRedeemRequest;
    }

    Vars internal _before;
    Vars internal _after;
    OpType internal currentOperation;

    modifier updateGhosts() {
        currentOperation = OpType.GENERIC;
        __before();
        _;
        __after();
    }

    modifier updateGhostsWithType(OpType op) {
        currentOperation = op;
        __before();
        _;
        __after();
    }

    function __before() internal {
        _before.ghostUnlockedPoolId = hub.unlockedPoolId();
        _before.ghostDebited = accounting.debited();
        _before.ghostCredited = accounting.credited();
        
        for (uint256 i = 0; i < createdPools.length; i++) {
            address[] memory _actors = _getActors();
            PoolId poolId = createdPools[i];
            _before.ghostEpochId[poolId] = multiShareClass.epochId(poolId);
            // loop through all share classes for the pool
            for (uint32 j = 0; j < multiShareClass.shareClassCount(poolId); j++) {
                ShareClassId scId = multiShareClass.previewShareClassId(poolId, j);
                AssetId assetId = poolRegistry.currency(poolId);
                
                (,_before.ghostLatestRedeemApproval,,) = multiShareClass.epochPointers(scId, assetId);
                
                // loop over all actors
                for (uint256 k = 0; k < _actors.length; k++) {
                    bytes32 actor = Helpers.addressToBytes32(_actors[k]);
                    (uint128 pendingRedeem, uint32 lastUpdate) = multiShareClass.redeemRequest(scId, assetId, actor);
                    _before.ghostRedeemRequest[scId][assetId][actor] = UserOrder({pending: pendingRedeem, lastUpdate: lastUpdate});
                }
            }
        }
    }

    function __after() internal {
        _after.ghostUnlockedPoolId = hub.unlockedPoolId();
        _after.ghostDebited = accounting.debited();
        _after.ghostCredited = accounting.credited();
        
        for (uint256 i = 0; i < createdPools.length; i++) {
            address[] memory _actors = _getActors();
            PoolId poolId = createdPools[i];
            _after.ghostEpochId[poolId] = multiShareClass.epochId(poolId);
            // loop through all share classes for the pool
            for (uint32 j = 0; j < multiShareClass.shareClassCount(poolId); j++) {
                ShareClassId scId = multiShareClass.previewShareClassId(poolId, j);
                AssetId assetId = poolRegistry.currency(poolId);
                
                (,_after.ghostLatestRedeemApproval,,) = multiShareClass.epochPointers(scId, assetId);
                
                // loop over all actors
                for (uint256 k = 0; k < _actors.length; k++) {
                    bytes32 actor = Helpers.addressToBytes32(_actors[k]);
                    (uint128 pendingRedeem, uint32 lastUpdate) = multiShareClass.redeemRequest(scId, assetId, actor);
                    _after.ghostRedeemRequest[scId][assetId][actor] = UserOrder({pending: pendingRedeem, lastUpdate: lastUpdate});
                }
            }
        }
    }
}