// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract JsonRegistry is Script {
    string deploymentOutput;
    uint256 registeredContracts = 0;

    uint64 startTime = uint64(block.timestamp);

    function register(string memory name, address target) public {
        deploymentOutput = (registeredContracts == 0)
            ? string(abi.encodePacked(deploymentOutput, '    "', name, '": "', vm.toString(target), '"'))
            : string(abi.encodePacked(deploymentOutput, ',\n    "', name, '": "', vm.toString(target), '"'));

        registeredContracts += 1;
    }

    function startDeploymentOutput(bool isTests) public {
        deploymentOutput = '{\n  "contracts": {\n';

        if (!isTests) {
            console.log(
                "\n\n---------\n\nStarting deployment: %s_%s\n\n", vm.toString(block.chainid), vm.toString(startTime)
            );
        }
    }

    function saveDeploymentOutput() public {
        string memory path = string(
            abi.encodePacked("./deployments/latest/", vm.toString(block.chainid), "_", vm.toString(startTime), ".json")
        );
        deploymentOutput = string(abi.encodePacked(deploymentOutput, "\n  }\n}\n"));
        vm.writeFile(path, deploymentOutput);
    }
}
