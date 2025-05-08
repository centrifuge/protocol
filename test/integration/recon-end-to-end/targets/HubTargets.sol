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
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
    
    /// === Permissionless Functions === ///
    function hub_createPool(uint64 poolIdAsUint, address admin, uint128 assetIdAsUint) public updateGhosts asActor returns (PoolId poolId) {
        PoolId _poolId = PoolId.wrap(poolIdAsUint);
        AssetId _assetId = AssetId.wrap(assetIdAsUint); 

        hub.createPool(_poolId, admin, _assetId);

        _addPool(_poolId.raw());

        return _poolId;
    }

    function hub_createPool_clamped(uint64 poolIdAsUint, uint128 assetEntropy) public updateGhosts asActor returns (PoolId poolId) {
        AssetId _assetId = Helpers.getRandomAssetId(createdAssetIds, assetEntropy); 

        hub_createPool(poolIdAsUint, _getActor(), _assetId.raw());
    }

    /// @dev The investor is explicitly clamped to one of the actors to make checking properties over all actors easier 
    /// @dev Property: After successfully calling claimDeposit for an investor (via notifyDeposit), their depositRequest[..].lastUpdate equals the nowDepositEpoch for the redeem
    function hub_notifyDeposit(uint128 assetIdAsUint, uint32 maxClaims) public updateGhosts asActor {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        bytes32 investor = CastLib.toBytes32(_getActor());
        uint256 investorSharesBefore =  token.balanceOf(_getActor());
        
        hub.notifyDeposit(poolId, scId, assetId, investor, maxClaims);

        (, uint32 lastUpdate) = shareClassManager.depositRequest(scId, assetId, investor);
        (uint32 depositEpochId,,, )= shareClassManager.epochId(scId, assetId);
        uint256 investorSharesAfter =  token.balanceOf(_getActor());

        uint256 investorShareDelta = investorSharesAfter - investorSharesBefore;
        sumOfFullfilledDeposits[address(token)] += investorShareDelta;
        executedInvestments[address(token)] += investorShareDelta;

        // nowDepositEpoch = depositEpochId + 1
        eq(lastUpdate, depositEpochId + 1, "lastUpdate != nowDepositEpoch");

        __globals();
    }

    function hub_notifyDeposit_clamped(uint32 maxClaims) public updateGhosts asActor {
        AssetId assetId = hubRegistry.currency(PoolId.wrap(_getPool()));
        bytes32 investor = CastLib.toBytes32(_getActor());

        hub_notifyDeposit(assetId.raw(), maxClaims);
    }

    /// @dev Property: After successfully claimRedeem for an investor (via notifyRedeem), their depositRequest[..].lastUpdate equals the nowRedeemEpoch for the redemption
    function hub_notifyRedeem(uint128 assetIdAsUint, uint32 maxClaims) public updateGhosts asActor {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        bytes32 investor = CastLib.toBytes32(_getActor());
        uint256 investorSharesBefore =  token.balanceOf(_getActor());
        hub.notifyRedeem(poolId, scId, assetId, investor, maxClaims);

        (, uint32 lastUpdate) = shareClassManager.redeemRequest(scId, assetId, investor);
        (, uint32 redeemEpochId,, )= shareClassManager.epochId(scId, assetId);
        uint256 investorSharesAfter =  token.balanceOf(_getActor());
        uint256 investorShareDelta = investorSharesAfter - investorSharesBefore;
        
        executedRedemptions[address(token)] += investorShareDelta;

        // nowRedeemEpoch = redeemEpochId + 1
        eq(lastUpdate, redeemEpochId + 1, "lastUpdate != nowRedeemEpoch");

        __globals();
    }

    function hub_notifyRedeem_clamped(uint32 maxClaims) public updateGhosts asActor {
        AssetId assetId = hubRegistry.currency(PoolId.wrap(_getPool()));

        hub_notifyRedeem(assetId.raw(), maxClaims);
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