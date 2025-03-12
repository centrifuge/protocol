 // SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {BeforeAfter} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";
// Chimera deps
import {vm} from "@chimera/Hevm.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
import "src/pools/PoolManager.sol";

abstract contract AdminTargets is
    BaseTargetFunctions,
    Properties
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///


    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    // === PoolManager === //
    /// Gateway owner methods: these get called directly because we're not using the gateway in our setup

    function poolManager_registerAsset(uint32 isoCode) public asAdmin {
        AssetId assetId_ = newAssetId(isoCode); 

        string memory name = MockERC20(_getAsset()).name();
        string memory symbol = MockERC20(_getAsset()).symbol();
        uint8 decimals = MockERC20(_getAsset()).decimals();

        poolManager.registerAsset(assetId_, name, symbol, decimals);
    }  

    function poolManager_depositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, uint32 isoCode, uint128 amount) public asAdmin {
        AssetId depositAssetId = newAssetId(isoCode);

        poolManager.depositRequest(poolId, scId, investor, depositAssetId, amount);
    }  

    function poolManager_redeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, uint32 isoCode, uint128 amount) public asAdmin {
        AssetId payoutAssetId = newAssetId(isoCode);

        poolManager.redeemRequest(poolId, scId, investor, payoutAssetId, amount);
    }  

    function poolManager_cancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId) public asAdmin {
        poolManager.cancelDepositRequest(poolId, scId, investor, depositAssetId);
    }

    function poolManager_cancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId) public asAdmin {
        poolManager.cancelRedeemRequest(poolId, scId, investor, payoutAssetId);
    }

    // === PoolRouter === //
    function poolRouter_execute(PoolId poolId, bytes[] memory data) public payable asAdmin {
        poolRouter.execute{value: msg.value}(poolId, data);
    }

    function poolRouter_execute_clamped(PoolId poolId) public payable asAdmin {
        // TODO: clamp poolId here to one of the created pools
        poolRouter.execute{value: msg.value}(poolId, queuedCalls);

        queuedCalls = new bytes[](0);
    }

    // === SingleShareClass === //

    function singleShareClass_claimDepositUntilEpoch(PoolId poolId, ShareClassId shareClassId_, bytes32 investor, AssetId depositAssetId, uint32 endEpochId) public asAdmin {
        singleShareClass.claimDepositUntilEpoch(poolId, shareClassId_, investor, depositAssetId, endEpochId);
    }

    function singleShareClass_claimRedeemUntilEpoch(PoolId poolId, ShareClassId shareClassId_, bytes32 investor, AssetId payoutAssetId, uint32 endEpochId) public asAdmin {
        singleShareClass.claimRedeemUntilEpoch(poolId, shareClassId_, investor, payoutAssetId, endEpochId);
    }

    function singleShareClass_issueSharesUntilEpoch(PoolId poolId, ShareClassId shareClassId_, AssetId depositAssetId, D18 navPerShare, uint32 endEpochId) public asAdmin {
        singleShareClass.issueSharesUntilEpoch(poolId, shareClassId_, depositAssetId, navPerShare, endEpochId);
    }

    function singleShareClass_revokeSharesUntilEpoch(PoolId poolId, ShareClassId shareClassId_, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation, uint32 endEpochId) public asAdmin {
        singleShareClass.revokeSharesUntilEpoch(poolId, shareClassId_, payoutAssetId, navPerShare, valuation, endEpochId);
    }

    function singleShareClass_updateMetadata(PoolId poolId, ShareClassId shareClassId_, string memory name, string memory symbol, bytes32 salt, bytes memory data) public asActor {
        singleShareClass.updateMetadata(PoolId(poolId), ShareClassId(shareClassId_), name, symbol, salt, data);
    }
}