// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {console2} from "forge-std/console2.sol";

// Recon Helpers
import {Panic} from "@recon/Panic.sol";

// Dependencies
import {Hub} from "src/hub/Hub.sol";

// Interfaces
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";

// Types
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {PoolId, newPoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

// Test Utils
import {Helpers} from "test/pools/fuzzing/recon-pools/utils/Helpers.sol";
import {BeforeAfter, OpType} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";

abstract contract HubTargets is
    BaseTargetFunctions,
    Properties
{

    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
    
    /// === Permissionless Functions === ///
    function hub_createPool(address admin, uint32 isoCode) public updateGhosts asActor returns (PoolId poolId) {
        AssetId assetId_ = newAssetId(isoCode); 

        poolId = hub.createPool(admin, assetId_);

        poolCreated = true;
        createdPools.push(poolId);

        return poolId;
    }

    /// @dev The investor is explicitly clamped to one of the actors to make checking properties over all actors easier 
    /// @dev Property: after successfully calling claimDeposit for an investor, their depositRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: The total pending deposit amount pendingDeposit[..] is always >= the sum of pending user deposit amounts depositRequest[..]
    function hub_claimDeposit(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint32 isoCode) public updateGhosts asActor {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = newAssetId(isoCode);
        bytes32 investor = Helpers.addressToBytes32(_getActor());
        
        hub.claimDeposit(poolId, scId, assetId, investor);

        (, uint32 lastUpdate) = shareClassManager.depositRequest(scId, assetId, investor);
        uint32 epochId = shareClassManager.epochId(poolId);

        eq(lastUpdate, epochId, "lastUpdate is not equal to epochId");
    }

    /// @dev The investor is explicitly clamped to one of the actors to make checking properties over all actors easier 
    /// @dev Property: After successfully calling claimRedeem for an investor, their redeemRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    function hub_claimRedeem(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint32 isoCode) public updateGhosts asActor {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = newAssetId(isoCode);
        bytes32 investor = Helpers.addressToBytes32(_getActor());
        
        hub.claimRedeem(poolId, scId, assetId, investor);

        (, uint32 lastUpdate) = shareClassManager.redeemRequest(scId, assetId, investor);
        uint32 epochId = shareClassManager.epochId(poolId);

        eq(lastUpdate, epochId, "lastUpdate is not equal to current epochId");
    }

    /// === EXECUTION FUNCTIONS === ///

    /// @dev Multicall is publicly exposed without access protections so can be called by anyone
    function hub_multicall(bytes[] memory data) public payable updateGhostsWithType(OpType.BATCH) asActor {
        hub.multicall{value: msg.value}(data);
    }

    /// @dev Makes a call directly to the unclamped handler so doesn't include asActor modifier or else would cause errors with foundry testing
    function hub_multicall_clamped() public payable {
        this.hub_multicall{value: msg.value}(queuedCalls);

        queuedCalls = new bytes[](0);
    }
}