// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {vm} from "@chimera/Hevm.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";

import {BeforeAfter} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";

import "src/pools/PoolRouter.sol";
import "src/misc/interfaces/IERC7726.sol";

abstract contract PoolRouterTargets is
    BaseTargetFunctions,
    Properties
{

    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
    
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