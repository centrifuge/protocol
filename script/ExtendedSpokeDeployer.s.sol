// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/Guardian.sol";

import {VaultsDeployer} from "script/VaultsDeployer.s.sol";
import {HooksDeployer} from "script/HooksDeployer.s.sol";
import {ManagersDeployer} from "script/ManagersDeployer.s.sol";
import {CommonInput} from "script/CommonDeployer.s.sol";

import "forge-std/Script.sol";

contract ExtendedSpokeDeployer is VaultsDeployer, HooksDeployer, ManagersDeployer {
    function deployExtendedSpoke(CommonInput memory input, address deployer) public {
        deployVaults(input, deployer);
        deployHooks(input, deployer);
        deployManagers(input, deployer);
    }

    function removeExtendedSpokeDeployerAccess(address deployer) public {
        removeVaultsDeployerAccess(deployer);
        removeHooksDeployerAccess(deployer);
        removeManagersDeployerAccess(deployer);
    }
}
