// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonInput} from "./CommonDeployer.s.sol";
import {ValuationsDeployer, ValuationsActionBatcher} from "./ValuationsDeployer.s.sol";
import {HubManagersDeployer, HubManagersActionBatcher} from "./HubManagersDeployer.s.sol";

import "forge-std/Script.sol";

contract ExtendedHubActionBatcher is ValuationsActionBatcher, HubManagersActionBatcher {}

contract ExtendedHubDeployer is ValuationsDeployer, HubManagersDeployer {
    function deployExtendedHub(CommonInput memory input, ExtendedHubActionBatcher batcher) public {
        _preDeployExtendedHub(input, batcher);
        _postDeployExtendedHub(batcher);
    }

    function _preDeployExtendedHub(CommonInput memory input, ExtendedHubActionBatcher batcher) internal {
        _preDeployValuations(input, batcher);
        _preDeployHubManagers(input, batcher);
    }

    function _postDeployExtendedHub(ExtendedHubActionBatcher batcher) internal {
        _postDeployValuations(batcher);
        _postDeployHubManagers(batcher);
    }

    function removeExtendedHubDeployerAccess(ExtendedHubActionBatcher batcher) public {
        removeValuationsDeployerAccess(batcher);
        removeHubManagersDeployerAccess(batcher);
    }
}
