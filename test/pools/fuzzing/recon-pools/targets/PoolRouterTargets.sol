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
import {BeforeAfter, OpType} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";

abstract contract PoolRouterTargets is
    BaseTargetFunctions,
    Properties
{

    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
    
    /// === Permissionless Functions === ///
    function poolRouter_createPool(address admin, uint32 isoCode, IShareClassManager shareClassManager) public updateGhosts asActor returns (PoolId poolId) {
        AssetId assetId_ = newAssetId(isoCode); 
        
        poolId = poolRouter.createPool(admin, assetId_, shareClassManager);
        poolCreated = true;
        createdPools.push(poolId);

        return poolId;
    }

    /// @dev Property: after successfully calling claimDeposit for an investor, their depositRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev The investor is explicitly clamped to one of the actors to make checking properties over all actors easier 
    function poolRouter_claimDeposit(PoolId poolId, ShareClassId scId, uint32 isoCode) public updateGhosts asActor {
        AssetId assetId = newAssetId(isoCode);
        bytes32 investor = Helpers.addressToBytes32(_getActor());
        
        poolRouter.claimDeposit(poolId, scId, assetId, investor);

        (, uint32 lastUpdate) = multiShareClass.depositRequest(scId, assetId, investor);
        uint32 epochId = multiShareClass.epochId(poolId);

        eq(lastUpdate, epochId, "lastUpdate is not equal to epochId");
    }

    /// @dev The investor is explicitly clamped to one of the actors to make checking properties over all actors easier 
    /// @dev Property: After successfully calling claimRedeem for an investor, their redeemRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    function poolRouter_claimRedeem(PoolId poolId, ShareClassId scId, uint32 isoCode) public updateGhosts asActor {
        AssetId assetId = newAssetId(isoCode);
        bytes32 investor = Helpers.addressToBytes32(_getActor());
        
        poolRouter.claimRedeem(poolId, scId, assetId, investor);

        (, uint32 lastUpdate) = multiShareClass.redeemRequest(scId, assetId, investor);
        uint32 epochId = multiShareClass.epochId(poolId);

        eq(lastUpdate, epochId, "lastUpdate is not equal to current epochId");
    }

    /// === EXECUTION FUNCTIONS === ///

    /// @dev Multicall is publicly exposed without access protections so can be called by anyone
    function poolRouter_multicall(bytes[] memory data) public payable updateGhostsWithType(OpType.BATCH) asActor {
        poolRouter.multicall{value: msg.value}(data);
    }

    /// @dev Makes a call directly to the unclamped handler so doesn't include asActor modifier or else would cause errors with foundry testing
    function poolRouter_multicall_clamped() public payable {
        this.poolRouter_multicall{value: msg.value}(queuedCalls);

        queuedCalls = new bytes[](0);
    }
}