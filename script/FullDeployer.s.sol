// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/Guardian.sol";

import {HubDeployer} from "script/HubDeployer.s.sol";
import {SpokeDeployer} from "script/SpokeDeployer.s.sol";

import "forge-std/Script.sol";

contract FullDeployer is HubDeployer, SpokeDeployer {
    
    function deployFull(uint16 centrifugeId_, ISafe adminSafe_, address deployer, bool isTests) public {
        deployHub(centrifugeId_, adminSafe_, deployer, isTests);
        deploySpoke(centrifugeId_, adminSafe_, deployer, isTests);
    }

    function run() public virtual {
        vm.startBroadcast();
        uint16 centrifugeId;
        string memory environment;
        string memory network;

        try vm.envString("NETWORK") returns (string memory _network) {
            network = _network;
            string memory configFile = string.concat("env/", network, ".json");
            string memory config = vm.readFile(configFile);
            centrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));
            environment = vm.parseJsonString(config, "$.network.environment");
        } catch {
            console.log("NETWORK environment variable is not set, this must be a mocked test");
            revert("NETWORK environment variable is required");
        }
        
        console.log("Network:", network);
        console.log("Environment:", environment);

        // Use the regular deployment functions - they now use CreateX internally
        deployFull(centrifugeId, ISafe(vm.envAddress("ADMIN")), msg.sender, false);
        
        // Since `wire()` is not called, separately adding the safe here
        guardian.file("safe", address(adminSafe));
        saveDeploymentOutput();
        vm.stopBroadcast();

        removeFullDeployerAccess(msg.sender, environment);
    }

    function removeFullDeployerAccess(address deployer, string memory environment) public {
        bool isNotMainnet = keccak256(abi.encodePacked(environment)) != keccak256(abi.encodePacked("mainnet"));

        if (!isNotMainnet) {
            removeHubDeployerAccess(deployer);
            removeSpokeDeployerAccess(deployer);
        }
    }
}
