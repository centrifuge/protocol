// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonInput} from "script/CommonDeployer.s.sol";
import {HooksDeployer, HooksActionBatcher} from "script/HooksDeployer.s.sol";
import {VaultsDeployer, VaultsActionBatcher} from "script/VaultsDeployer.s.sol";
import {ManagersDeployer, ManagersActionBatcher} from "script/ManagersDeployer.s.sol";

import "forge-std/Script.sol";

contract ExtendedSpokeActionBatcher is VaultsActionBatcher, HooksActionBatcher, ManagersActionBatcher {}

contract ExtendedSpokeDeployer is VaultsDeployer, HooksDeployer, ManagersDeployer {
    function deployExtendedSpoke(CommonInput memory input, ExtendedSpokeActionBatcher batcher) public {
        deployVaults(input, batcher);
        deployHooks(input, batcher);
        deployManagers(input, batcher);
    }

    function removeExtendedSpokeDeployerAccess(ExtendedSpokeActionBatcher batcher) public {
        removeVaultsDeployerAccess(batcher);
        removeHooksDeployerAccess(batcher);
        removeManagersDeployerAccess(batcher);
    }
}
