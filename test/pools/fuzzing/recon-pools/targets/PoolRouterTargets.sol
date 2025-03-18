// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {vm} from "@chimera/Hevm.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";

import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
import "src/pools/PoolRouter.sol";
import "src/misc/interfaces/IERC7726.sol";

import {Helpers} from "test/pools/fuzzing/recon-pools/utils/Helpers.sol";
import {BeforeAfter} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";

abstract contract PoolRouterTargets is
    BaseTargetFunctions,
    Properties
{

    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    /// CLAMPED HANDLERS /// 
    function poolRouter_claimDeposit_clamped(PoolId poolId, ShareClassId scId, uint32 isoCode) public updateGhosts asActor {
        bytes32 investor = Helpers.addressToBytes32(_getActor());
        AssetId assetId = newAssetId(isoCode);

        poolRouter.claimDeposit(poolId, scId, assetId, investor);
    }

    function poolRouter_claimRedeem_clamped(PoolId poolId, ShareClassId scId, uint32 isoCode) public updateGhosts asActor {
        bytes32 investor = Helpers.addressToBytes32(_getActor());
        AssetId assetId = newAssetId(isoCode);
        
        poolRouter.claimRedeem(poolId, scId, assetId, investor);
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
    
    /// === Permissionless Functions === ///
    function poolRouter_createPool(address admin, uint32 isoCode, IShareClassManager shareClassManager) public updateGhosts asActor returns (PoolId poolId) {
        AssetId assetId_ = newAssetId(isoCode); 
        
        poolId = poolRouter.createPool(admin, assetId_, shareClassManager);
        poolCreated = true;
        createdPools.push(poolId);

        return poolId;
    }

    function poolRouter_claimDeposit(PoolId poolId, ShareClassId scId, uint32 isoCode, bytes32 investor) public updateGhosts asActor {
        AssetId assetId = newAssetId(isoCode);
        
        poolRouter.claimDeposit(poolId, scId, assetId, investor);
    }

    function poolRouter_claimRedeem(PoolId poolId, ShareClassId scId, uint32 isoCode, bytes32 investor) public updateGhosts asActor {
        AssetId assetId = newAssetId(isoCode);
        
        poolRouter.claimRedeem(poolId, scId, assetId, investor);
    }

    /// === EXECUTION FUNCTIONS === ///
    /// Multicall is publicly exposed without access protections so can be called by anyone
    function poolRouter_multicall(bytes[] memory data) public payable updateGhosts asActor {
        poolRouter.multicall{value: msg.value}(data);
    }

    function poolRouter_multicall_clamped() public payable updateGhosts asActor {
        poolRouter.multicall{value: msg.value}(queuedCalls);

        queuedCalls = new bytes[](0);
    }
}