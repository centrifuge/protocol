// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/Guardian.sol";

import "forge-std/Script.sol";
import {HubDeployer} from "script/HubDeployer.s.sol";
import {SpokeDeployer} from "script/SpokeDeployer.s.sol";

contract FullDeployer is HubDeployer, SpokeDeployer {
    function deployFull(
        uint16 centrifugeId,
        ISafe adminSafe_,
        address deployer,
        bool isTests
    ) public {
        deployHub(centrifugeId, adminSafe_, deployer, isTests);
        deploySpoke(centrifugeId, adminSafe_, deployer, isTests);
    }

    function removeFullDeployerAccess(address deployer) public {
        removeHubDeployerAccess(deployer);
        removeSpokeDeployerAccess(deployer);
    }
}
