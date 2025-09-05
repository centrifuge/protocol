// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract JsonRegistry is Script {
    string deploymentOutput;
    uint256 registeredContracts = 0;
    bool shouldLabelAddresses;
    string addressLabelPrefix;

    function register(string memory name, address target) public {
        deploymentOutput = (registeredContracts == 0)
            ? string(abi.encodePacked(deploymentOutput, '    "', name, '": "', vm.toString(target), '"'))
            : string(abi.encodePacked(deploymentOutput, ',\n    "', name, '": "', vm.toString(target), '"'));

        registeredContracts += 1;

        if (shouldLabelAddresses) {
            vm.label(target, string(abi.encodePacked(addressLabelPrefix, name)));
        }
    }

    function labelAddresses(string memory prefix) public {
        shouldLabelAddresses = true;
        addressLabelPrefix = prefix;
    }

    function startDeploymentOutput() public {
        deploymentOutput = '{\n  "contracts": {\n';
    }

    function saveDeploymentOutput() public {
        string memory dir = "./env/latest/";
        if (!vm.exists(dir)) {
            vm.createDir(dir, true);
        }

        // Save with timestamp for history
        string memory timestampedPath = string(
            abi.encodePacked(
                dir,
                "_chain",
                vm.toString(block.chainid),
                "_block",
                vm.toString(block.number),
                "_nonce",
                vm.toString(vm.getNonce(msg.sender)),
                ".json"
            )
        );
        deploymentOutput = string(abi.encodePacked(deploymentOutput, "\n  }\n}\n"));
        vm.writeFile(timestampedPath, deploymentOutput);
        console.log("Contract addresses saved to: %s", timestampedPath);

        // Save as latest
        string memory latestPath = string(abi.encodePacked(dir, vm.toString(block.chainid), "-latest.json"));

        vm.writeFile(latestPath, deploymentOutput);
        console.log("Contract addresses also saved to: %s", latestPath);
    }
}
