// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {BeforeAfter} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";
// Chimera deps
import {vm} from "@chimera/Hevm.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";

import "src/pools/PoolManager.sol";

abstract contract PoolManagerTargets is
    BaseTargetFunctions,
    Properties
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///


    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function poolManager_claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) public asActor {
        poolManager.claimDeposit(poolId, scId, assetId, investor);
    }

    function poolManager_claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) public asActor {
        poolManager.claimRedeem(poolId, scId, assetId, investor);
    }

}