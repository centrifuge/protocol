// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/Guardian.sol";

import "forge-std/Script.sol";
import {HubDeployer} from "script/HubDeployer.s.sol";
import {SpokeDeployer} from "script/SpokeDeployer.s.sol";

contract FullDeployer is HubDeployer, SpokeDeployer {
    function deployFull(uint16 centrifugeId_, ISafe adminSafe_, address deployer, bool isTests) public {
        deployHub(centrifugeId_, adminSafe_, deployer, isTests);
        deploySpoke(centrifugeId_, adminSafe_, deployer, isTests);
    }

    function run() public {
        vm.startBroadcast();
        uint16 centrifugeId;

        try vm.envString("NETWORK") returns (string memory network) {
            string memory configFile = string.concat("env/", network, ".json");
            string memory config = vm.readFile(configFile);
            centrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));
        } catch {
            console.log("NETWORK environment variable is not set, this must be a mocked test");
            revert("NETWORK environment variable is required");
        }

        deployFull(centrifugeId, ISafe(vm.envAddress("ADMIN")), msg.sender, false);
        // Since `wire()` is not called, separately adding the safe here
        guardian.file("safe", address(adminSafe));
        saveDeploymentOutput();
        vm.stopBroadcast();
    }

    function removeFullDeployerAccess(address deployer) public {
        bool isTestnet;

        try vm.envString("NETWORK") returns (string memory network) {
            string memory configFile = string.concat("env/", network, ".json");
            string memory config = vm.readFile(configFile);
            string memory environment = vm.parseJsonString(config, "$.network.environment");
            isTestnet = keccak256(bytes(environment)) == keccak256(bytes("testnet"));
        } catch {
            console.log("NETWORK environment variable is not set, this must be a mocked test");
        }

        if (!isTestnet) {
            removeHubDeployerAccess(deployer);
            removeSpokeDeployerAccess(deployer);
        }
    }
}
