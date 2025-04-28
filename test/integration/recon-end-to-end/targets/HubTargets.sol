// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";
import {console2} from "forge-std/console2.sol";

// Recon Helpers
import {Panic} from "@recon/Panic.sol";
import {MockERC20} from "@recon/MockERC20.sol";

// Dependencies
import {Hub} from "src/hub/Hub.sol";
// Interfaces
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";

// Types
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {PoolId, newPoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

// Test Utils
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";
import {BeforeAfter, OpType} from "../BeforeAfter.sol";
import {Properties} from "test/integration/recon-end-to-end/properties/Properties.sol";

abstract contract HubTargets is
    BaseTargetFunctions,
    Properties
{
    using CastLib for *;
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
    
    /// === Permissionless Functions === ///
    function hub_createPool(address admin, uint128 assetIdAsUint) public updateGhosts asActor returns (PoolId poolId) {
        AssetId assetId_ = AssetId.wrap(assetIdAsUint); 

        poolId = hub.createPool(admin, assetId_);

        createdPools.push(poolId);

        return poolId;
    }

    /// @dev The investor is explicitly clamped to one of the actors to make checking properties over all actors easier 
    /// @dev Property: after successfully calling claimDeposit for an investor, their depositRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    /// @dev Property: The total pending deposit amount pendingDeposit[..] is always >= the sum of pending user deposit amounts depositRequest[..]
    function hub_claimDeposit(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint) public updateGhosts {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        bytes32 investor = _getActor().toBytes32();
        
        (, uint32 lastUpdateBefore) = shareClassManager.depositRequest(scId, assetId, investor);
        (,, uint32 latestIssuance,) = shareClassManager.epochPointers(scId, assetId);
        (,,,,uint128 pendingDepositBefore,, uint128 claimableCancelDepositRequestBefore,,,) = asyncRequests.investments(address(vault), _getActor());

        vm.prank(_getActor());
        hub.claimDeposit(poolId, scId, assetId, investor);

        (,,,,uint128 pendingDepositAfter,, uint128 claimableCancelDepositRequestAfter,,,) = asyncRequests.investments(address(vault), _getActor());
        uint128 paymentAssetAmount = pendingDepositBefore - pendingDepositAfter;
        uint128 cancelledAmount = claimableCancelDepositRequestAfter - claimableCancelDepositRequestBefore;
        // ghost tracking
        depositProcessed[_getActor()] += paymentAssetAmount;
        cancelledDeposits[_getActor()] += cancelledAmount;

        (, uint32 lastUpdateAfter) = shareClassManager.depositRequest(scId, assetId, investor);
        uint32 epochId = shareClassManager.epochId(poolId);

        // If the latestIssuance is < lastUpdateBefore, the user can't have claimed yet but their epochId is still updated
        if(latestIssuance >= lastUpdateBefore) {
            eq(lastUpdateAfter, epochId, "lastUpdate is not equal to epochId");
        }
    }

    function hub_claimDeposit_clamped(uint64 poolIdAsUint, uint32 scIdEntropy) public updateGhosts asActor {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdAsUint);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scIdEntropy);
        AssetId assetId = hubRegistry.currency(poolId);

        hub_claimDeposit(poolId.raw(), scId.raw(), assetId.raw());
    }

    /// @dev The investor is explicitly clamped to one of the actors to make checking properties over all actors easier 
    /// @dev Property: After successfully calling claimRedeem for an investor, their redeemRequest[..].lastUpdate equals the current epoch id epochId[poolId]
    function hub_claimRedeem(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 assetIdAsUint) public updateGhosts asActor {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        ShareClassId scId = ShareClassId.wrap(scIdAsBytes);
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        bytes32 investor = _getActor().toBytes32();
        
        (,,,,,uint128 pendingRedeemRequestBefore,, uint128 claimableCancelRedeemRequestBefore,,) = asyncRequests.investments(address(vault), _getActor());

        vm.prank(_getActor());
        hub.claimRedeem(poolId, scId, assetId, investor);

        (,,,,,uint128 pendingRedeemRequestAfter,, uint128 claimableCancelRedeemRequestAfter,,) = asyncRequests.investments(address(vault), _getActor());
        uint128 paymentShareAmount = pendingRedeemRequestBefore - pendingRedeemRequestAfter;
        uint128 cancelledShareAmount = claimableCancelRedeemRequestAfter - claimableCancelRedeemRequestBefore;
        
        // ghost tracking
        redemptionsProcessed[_getActor()] += paymentShareAmount;
        cancelledRedemptions[_getActor()] += cancelledShareAmount;

        (, uint32 lastUpdate) = shareClassManager.redeemRequest(scId, assetId, investor);
        uint32 epochId = shareClassManager.epochId(poolId);

        eq(lastUpdate, epochId, "lastUpdate is not equal to current epochId");
    }

    function hub_claimRedeem_clamped(uint64 poolIdAsUint, uint32 scIdEntropy) public updateGhosts asActor {
        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolIdAsUint);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scIdEntropy);
        AssetId assetId = hubRegistry.currency(poolId);

        hub_claimRedeem(poolId.raw(), scId.raw(), assetId.raw());
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