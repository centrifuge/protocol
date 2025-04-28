// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {console2} from "forge-std/console2.sol";

// Recon Helpers
import {Panic} from "@recon/Panic.sol";

// Dependencies
import {Hub} from "src/hub/Hub.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

// Interfaces
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";

// Types
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {PoolId, newPoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

// Test Utils
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";
import {BeforeAfter, OpType} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";

abstract contract HubTargets is
    BaseTargetFunctions,
    Properties
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
    
    /// === Permissionless Functions === ///
    function hub_createPool(address admin, uint64 poolIdAsUint, uint128 assetIdAsUint) public updateGhosts asActor returns (PoolId poolId) {
        PoolId _poolId = PoolId.wrap(poolIdAsUint);
        AssetId _assetId = AssetId.wrap(assetIdAsUint); 

        hub.createPool(_poolId, admin, _assetId);

        poolCreated = true;
        createdPools.push(poolId);

        return poolId;
    }

    function hub_createPool_clamped(uint64 poolIdAsUint, uint128 assetEntropy) public updateGhosts asActor returns (PoolId poolId) {
        AssetId _assetId = _getRandomAssetId(assetEntropy); 

        hub_createPool(_getActor(), poolIdAsUint, _assetId.raw());
    }

    /// @dev The investor is explicitly clamped to one of the actors to make checking properties over all actors easier 
    /// @dev Property: after successfully calling claimDeposit for an investor, their depositRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: The total pending deposit amount pendingDeposit[..] is always >= the sum of pending user deposit amounts depositRequest[..]
    // TODO: fix this for latest changes to SCM and Hub 
    // this doesn't exist in the latest version of Hub so will most likely need to test on notifyDeposit which calls claimDeposit
    // function hub_claimDeposit(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint) public updateGhosts asActor {
    //     PoolId poolId = PoolId.wrap(poolIdAsUint);
    //     ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
    //     AssetId assetId = AssetId.wrap(assetIdAsUint);
    //     bytes32 investor = CastLib.toBytes32(_getActor());
        
    //     (, uint32 lastUpdateBefore) = shareClassManager.depositRequest(scId, assetId, investor);
    //     // (,, uint32 latestIssuance,) = shareClassManager.epochPointers(scId, assetId);

    //     hub.claimDeposit(poolId, scId, assetId, investor);

    //     (, uint32 lastUpdateAfter) = shareClassManager.depositRequest(scId, assetId, investor);
    //     uint32 epochId = shareClassManager.epochId(poolId);

    //     // If the latestIssuance is < lastUpdateBefore, the user can't have claimed yet but their epochId is still updated
    //     // if(latestIssuance >= lastUpdateBefore) {
    //     //     eq(lastUpdateAfter, epochId, "lastUpdate is not equal to epochId");
    //     // }
    // }

    // function hub_claimDeposit_clamped(uint64 poolIdAsUint, uint32 scIdEntropy) public updateGhosts asActor {
    //     PoolId poolId = _getRandomPoolId(poolIdAsUint);
    //     ShareClassId scId = _getRandomShareClassIdForPool(poolId, scIdEntropy);
    //     AssetId assetId = hubRegistry.currency(poolId);

    //     hub_claimDeposit(poolId.raw(), scId.raw(), assetId.raw());
    // }

    function hub_notifyDeposit(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint32 maxClaims) public updateGhosts asActor {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        bytes32 investor = CastLib.toBytes32(_getActor());

        hub.notifyDeposit(poolId, scId, assetId, investor, maxClaims);
    }

    function hub_notifyDeposit_clamped(uint64 poolIdAsUint, uint32 scIdEntropy, uint128 assetIdAsUint, uint32 maxClaims) public updateGhosts asActor {
        PoolId poolId = _getRandomPoolId(poolIdAsUint);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scIdEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        bytes32 investor = CastLib.toBytes32(_getActor());

        hub_notifyDeposit(poolId.raw(), scId.raw(), assetId.raw(), maxClaims);
    }
    /// @dev The investor is explicitly clamped to one of the actors to make checking properties over all actors easier 
    /// @dev Property: After successfully calling claimRedeem for an investor, their redeemRequest[..].lastUpdate equals the current epoch id epochId[poolId]
        // TODO: fix this for latest changes to SCM and Hub 
    // this doesn't exist in the latest version of Hub so will most likely need to test on notifyDeposit which calls claimDeposit
    // function hub_claimRedeem(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint) public updateGhosts asActor {
    //     PoolId poolId = PoolId.wrap(poolIdAsUint);
    //     ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
    //     AssetId assetId = AssetId.wrap(assetIdAsUint);
    //     bytes32 investor = CastLib.toBytes32(_getActor());
        
    //     hub.claimRedeem(poolId, scId, assetId, investor);

    //     (, uint32 lastUpdate) = shareClassManager.redeemRequest(scId, assetId, investor);
    //     uint32 epochId = shareClassManager.epochId(poolId);

    //     // eq(lastUpdate, epochId, "lastUpdate is not equal to current epochId");
    // }

    // function hub_claimRedeem_clamped(uint64 poolIdAsUint, uint32 scIdEntropy) public updateGhosts asActor {
    //     PoolId poolId = _getRandomPoolId(poolIdAsUint);
    //     ShareClassId scId = _getRandomShareClassIdForPool(poolId, scIdEntropy);
    //     AssetId assetId = hubRegistry.currency(poolId);

    //     hub_claimRedeem(poolId.raw(), scId.raw(), assetId.raw());
    // }

    function hub_notifyRedeem(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint, uint32 maxClaims) public updateGhosts asActor {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        bytes32 investor = CastLib.toBytes32(_getActor());

        hub.notifyRedeem(poolId, scId, assetId, investor, maxClaims);
    }

    function hub_notifyRedeem_clamped(uint64 poolEntropy, uint32 scIdEntropy, uint32 maxClaims) public updateGhosts asActor {
        PoolId poolId = _getRandomPoolId(poolEntropy);
        ShareClassId scId = _getRandomShareClassIdForPool(poolId, scIdEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        bytes32 investor = CastLib.toBytes32(_getActor());

        hub_notifyRedeem(poolId, scId, assetId, investor, maxClaims);
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