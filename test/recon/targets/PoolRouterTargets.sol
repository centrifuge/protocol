// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {BeforeAfter} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";
// Chimera deps
import {vm} from "@chimera/Hevm.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";

import "src/pools/PoolRouter.sol";

abstract contract PoolRouterTargets is
    BaseTargetFunctions,
    Properties
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///


    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
    function poolRouter_execute(PoolId poolId, bytes[] memory data) public payable asActor {
        poolRouter.execute{value: msg.value}(poolId, data);
    }

    function poolRouter_multicall(bytes[] memory data) public payable asActor {
        poolRouter.multicall{value: msg.value}(data);
    }
}