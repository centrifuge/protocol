// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonInput} from "./CommonDeployer.s.sol";
import {HooksDeployer, HooksActionBatcher} from "./HooksDeployer.s.sol";
import {VaultsDeployer, VaultsActionBatcher} from "./VaultsDeployer.s.sol";
import {ManagersDeployer, ManagersActionBatcher} from "./ManagersDeployer.s.sol";

import "forge-std/Script.sol";

contract ExtendedSpokeActionBatcher is VaultsActionBatcher, HooksActionBatcher, ManagersActionBatcher {}

contract ExtendedSpokeDeployer is VaultsDeployer, HooksDeployer, ManagersDeployer {
    function deployExtendedSpoke(CommonInput memory input, ExtendedSpokeActionBatcher batcher) public {
        _preDeployExtendedSpoke(input, batcher);
        _postDeployExtendedSpoke(batcher);
    }

    function _preDeployExtendedSpoke(CommonInput memory input, ExtendedSpokeActionBatcher batcher) internal {
        _preDeployVaults(input, batcher);
        _preDeployHooks(input, batcher);
        _preDeployManagers(input, batcher);
    }

    function _postDeployExtendedSpoke(ExtendedSpokeActionBatcher batcher) internal {
        _postDeployVaults(batcher);
        _postDeployHooks(batcher);
        _postDeployManagers(batcher);
    }

    function removeExtendedSpokeDeployerAccess(ExtendedSpokeActionBatcher batcher) public {
        removeVaultsDeployerAccess(batcher);
        removeHooksDeployerAccess(batcher);
        removeManagersDeployerAccess(batcher);
    }
}
