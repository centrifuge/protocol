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
        preDeployExtendedSpoke(input, batcher);
        postDeployExtendedSpoke(batcher);
    }

    function preDeployExtendedSpoke(CommonInput memory input, ExtendedSpokeActionBatcher batcher) internal {
        preDeployVaults(input, batcher);
        preDeployHooks(input, batcher);
        preDeployManagers(input, batcher);
    }

    function postDeployExtendedSpoke(ExtendedSpokeActionBatcher batcher) internal {
        postDeployVaults(batcher);
        postDeployHooks(batcher);
        postDeployManagers(batcher);
    }

    function removeExtendedSpokeDeployerAccess(ExtendedSpokeActionBatcher batcher) public {
        removeVaultsDeployerAccess(batcher);
        removeHooksDeployerAccess(batcher);
        removeManagersDeployerAccess(batcher);
    }
}
