// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";

contract JsonRegistry is Script {
    string deploymentOutput;
    uint256 registeredContracts = 0;

    function register(string memory name, address target) public {
        deploymentOutput = (registeredContracts == 0)
            ? string(abi.encodePacked(deploymentOutput, '    "', name, '": "0x', vm.toString(target), '"'))
            : string(abi.encodePacked(deploymentOutput, ',\n    "', name, '": "0x', vm.toString(target), '"'));

        registeredContracts += 1;
    }

    function startDeploymentOutput() public {
        deploymentOutput = '{\n  "contracts": {\n';
    }

    function saveDeploymentOutput() public {
        string memory path = string(
            abi.encodePacked(
                "./deployments/latest/", vm.toString(block.chainid), "_", vm.toString(block.timestamp), ".json"
            )
        );
        deploymentOutput = string(abi.encodePacked(deploymentOutput, "\n  }\n}\n"));
        vm.writeFile(path, deploymentOutput);
    }
}
