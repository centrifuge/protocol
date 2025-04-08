// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/Guardian.sol";

import "forge-std/Script.sol";
import {HubDeployer} from "script/HubDeployer.s.sol";
import {VaultsDeployer} from "script/VaultsDeployer.s.sol";

contract FullDeployer is HubDeployer, VaultsDeployer {
    function deployFull(uint16 centrifugeId, ISafe adminSafe_, address deployer) public {
        deployHub(centrifugeId, adminSafe_, deployer);
        deployVaults(centrifugeId, adminSafe_, deployer);
    }

    function removeFullDeployerAccess(address deployer) public {
        removeHubDeployerAccess(deployer);
        removeVaultsDeployerAccess(deployer);
    }
}
