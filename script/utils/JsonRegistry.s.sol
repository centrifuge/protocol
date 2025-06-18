// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract JsonRegistry is Script {
    string deploymentOutput;
    uint256 registeredContracts = 0;

    function register(string memory name, address target) public {
        deploymentOutput = (registeredContracts == 0)
            ? string(abi.encodePacked(deploymentOutput, '    "', name, '": "', vm.toString(target), '"'))
            : string(abi.encodePacked(deploymentOutput, ',\n    "', name, '": "', vm.toString(target), '"'));

        registeredContracts += 1;
    }

    function startDeploymentOutput(bool isTests) public {
        deploymentOutput = '{\n  "contracts": {\n';

        if (!isTests) {
            console.log("\n\n---------\n\nStarting deployment for chain ID: %s\n\n", vm.toString(block.chainid));
        }
    }

    function saveDeploymentOutput() public {
        string memory dir = "./env/latest/";
        if (!vm.exists(dir)) {
            vm.createDir(dir, true);
        }

        // Save with timestamp for history
        string memory timestampedPath =
            string(abi.encodePacked(dir, vm.toString(block.chainid), "_", vm.toString(block.timestamp), ".json"));
        deploymentOutput = string(abi.encodePacked(deploymentOutput, "\n  }\n}\n"));
        vm.writeFile(timestampedPath, deploymentOutput);
        console.log("Contract addresses saved to: %s", timestampedPath);

        // Save as latest
        string memory latestPath = string(abi.encodePacked(dir, vm.toString(block.chainid), "-latest.json"));

        vm.writeFile(latestPath, deploymentOutput);
        console.log("Contract addresses also saved to: %s", latestPath);
    }
}
