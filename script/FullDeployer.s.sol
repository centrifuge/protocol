// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/Guardian.sol";

import "forge-std/Script.sol";
import {HubDeployer} from "script/HubDeployer.s.sol";
import {VaultsDeployer} from "script/VaultsDeployer.s.sol";

contract FullDeployer is HubDeployer, VaultsDeployer {
    function run() public {
        localCentrifugeId = uint16(vm.envUint("CENTRIFUGE_ID"));
        vm.startBroadcast();

        deployFull(ISafe(vm.envAddress("ADMIN")), msg.sender, false);
        removeFullDeployerAccess(msg.sender);
        saveDeploymentOutput();

        vm.stopBroadcast();
    }


    function deployFull(ISafe adminSafe_, address deployer, bool isTests) public {
        deployHub(adminSafe_, deployer, isTests);
        deployVaults(adminSafe_, deployer, isTests);
    }

    function removeFullDeployerAccess(address deployer) public {
        removeHubDeployerAccess(deployer);
        removeVaultsDeployerAccess(deployer);
    }
}
