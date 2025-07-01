// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonInput} from "script/CommonDeployer.s.sol";
import {HooksCBD, HooksDeployer} from "script/HooksDeployer.s.sol";
import {VaultsCBD, VaultsDeployer} from "script/VaultsDeployer.s.sol";
import {ManagersCBD, ManagersDeployer} from "script/ManagersDeployer.s.sol";

import "forge-std/Script.sol";
import {ICreateX} from "createx-forge/script/ICreateX.sol";

contract ExtendedSpokeCBD is VaultsCBD, HooksCBD, ManagersCBD {
    function deployExtendedSpoke(CommonInput memory input, ICreateX createX, address deployer) public {
        deployVaults(input, createX, deployer);
        deployHooks(input, createX, deployer);
        deployManagers(input, createX, deployer);
    }

    function removeExtendedSpokeDeployerAccess(address deployer) public {
        removeVaultsDeployerAccess(deployer);
        removeHooksDeployerAccess(deployer);
        removeManagersDeployerAccess(deployer);
    }
}

contract ExtendedSpokeDeployer is VaultsDeployer, HooksDeployer, ManagersDeployer, ExtendedSpokeCBD {
    function deployExtendedSpoke(CommonInput memory input, address deployer) public {
        super.deployExtendedSpoke(input, _createX(), deployer);
    }

    function extendedSpokeRegister() internal {
        vaultsRegister();
        hooksRegister();
        managersRegister();
    }
}
