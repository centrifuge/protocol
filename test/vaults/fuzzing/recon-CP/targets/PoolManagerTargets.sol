// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {vm} from "@chimera/Hevm.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";

// Source
import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
import "src/pools/PoolManager.sol";

import {BeforeAfter} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";
import {Helpers} from "../utils/Helpers.sol";

abstract contract PoolManagerTargets is
    BaseTargetFunctions,
    Properties
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    /// CLAMPED HANDLERS /// 
    function poolManager_claimDeposit_clamped(PoolId poolId, ShareClassId scId, uint32 isoCode) public asActor {
        bytes32 investor = Helpers.addressToBytes32(_getActor());
        AssetId assetId = newAssetId(isoCode);

        poolManager.claimDeposit(poolId, scId, assetId, investor);
    }

    function poolManager_claimRedeem_clamped(PoolId poolId, ShareClassId scId, uint32 isoCode) public asActor {
        bytes32 investor = Helpers.addressToBytes32(_getActor());
        AssetId assetId = newAssetId(isoCode);
        
        poolManager.claimRedeem(poolId, scId, assetId, investor);
    }

    // === PoolManager === //
    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function poolManager_createPool(address admin, uint32 isoCode, IShareClassManager shareClassManager) public asActor returns (PoolId poolId) {
        AssetId assetId_ = newAssetId(isoCode); 
        
        poolId = poolManager.createPool(admin, assetId_, shareClassManager);

        poolCreated = true;
        
        return poolId;
    }

    function poolManager_claimDeposit(PoolId poolId, ShareClassId scId, uint32 isoCode, bytes32 investor) public asActor {
        AssetId assetId = newAssetId(isoCode);
        
        poolManager.claimDeposit(poolId, scId, assetId, investor);
    }

    function poolManager_claimRedeem(PoolId poolId, ShareClassId scId, uint32 isoCode, bytes32 investor) public asActor {
        AssetId assetId = newAssetId(isoCode);
        
        poolManager.claimRedeem(poolId, scId, assetId, investor);
    }
    

}