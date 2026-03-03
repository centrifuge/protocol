// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract JsonRegistry is Script {
    string deploymentOutput;
    uint256 registeredContracts;
    string addressLabelPrefix;
    uint256 deploymentStartBlock;

    function register(string memory name, address target, string memory version) public {
        _register(
            name, string(abi.encodePacked('{ "address": "', vm.toString(target), '", "version": "', version, '" }'))
        );
    }

    function _register(string memory name, string memory value) internal {
        string memory contractJson = string(abi.encodePacked('    "', name, '": ', value));

        deploymentOutput = (registeredContracts == 0)
            ? string(abi.encodePacked(deploymentOutput, contractJson))
            : string(abi.encodePacked(deploymentOutput, ",\n", contractJson));

        registeredContracts += 1;
    }

    function startDeploymentOutput() public {
        registeredContracts = 0;
        deploymentOutput = '{\n  "contracts": {\n';
        deploymentStartBlock = block.number;
    }

    function saveDeploymentOutput() public {
        string memory dir = "./env/latest/";
        if (!vm.exists(dir)) {
            vm.createDir(dir, true);
        }

        // Add deployment start block to output if captured
        string memory blockJson = "";

        // forgefmt: disable-next-item
        if (deploymentStartBlock > 0)
        {
            blockJson = string(
                abi.encodePacked(
                    "\n  },\n  \"deploymentStartBlock\": \"",
                    vm.toString(deploymentStartBlock),
                    "\"\n}"
                )
            );
        } else {
            blockJson = "\n  }\n}";
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
        string memory fullOutput = string(abi.encodePacked(deploymentOutput, blockJson));
        vm.writeFile(timestampedPath, fullOutput);
        console.log("Contract addresses saved to: %s", timestampedPath);

        // Save as latest
        string memory latestPath = string(abi.encodePacked(dir, vm.toString(block.chainid), "-latest.json"));

        vm.writeFile(latestPath, fullOutput);
        console.log("Contract addresses also saved to: %s", latestPath);
    }
}
