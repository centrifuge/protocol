// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/Guardian.sol";

import "forge-std/Script.sol";
import {HubDeployer} from "script/HubDeployer.s.sol";
import {SpokeDeployer} from "script/SpokeDeployer.s.sol";

contract FullDeployer is HubDeployer, SpokeDeployer {
    function deployFull(uint16 centrifugeId, ISafe adminSafe_, address deployer, bool isTests) public {
        deployHub(centrifugeId, adminSafe_, deployer, isTests);
        deploySpoke(centrifugeId, adminSafe_, deployer, isTests);
    }

    function run() public {
        uint16 centrifugeId = uint16(vm.envUint("CENTRIFUGE_ID"));
        vm.startBroadcast();
        deployFull(centrifugeId, ISafe(vm.envAddress("ADMIN")), msg.sender, false);
        // Since `wire()` is not called, separately adding the safe here
        guardian.file("safe", address(adminSafe));
        saveDeploymentOutput();
        vm.stopBroadcast();
    }

    // function removeFullDeployerAccess(address deployer) public {
    //     removeHubDeployerAccess(deployer);
    //     removeSpokeDeployerAccess(deployer);
    // }
}
