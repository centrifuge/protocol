// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract JsonRegistry is Script {
    string deploymentOutput;
    uint256 registeredContracts = 0;
    bool shouldLaberAddresses;
    string addressLabelPrefix;

    function register(string memory name, address target) public {
        deploymentOutput = (registeredContracts == 0)
            ? string(abi.encodePacked(deploymentOutput, '    "', name, '": "', vm.toString(target), '"'))
            : string(abi.encodePacked(deploymentOutput, ',\n    "', name, '": "', vm.toString(target), '"'));

        registeredContracts += 1;

        if (shouldLaberAddresses) {
            vm.label(address(target), string(abi.encodePacked(addressLabelPrefix, name)));
        }
    }

    function labelAddresses(string memory prefix) public {
        shouldLaberAddresses = true;
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
                vm.toString(block.chainid),
                "_block",
                vm.toString(block.chainid),
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
