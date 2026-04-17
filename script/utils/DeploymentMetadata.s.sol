// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/// @title DeploymentMetadata
/// @notice Accumulates contract metadata (logical name, address, version) during deployment
///         and writes it as a temporary sidecar file alongside the Forge broadcast output.
///         The Python tooling then merges this into run-latest.json (under a `deploymentMetadata`
///         key) and deletes the sidecar, resulting in a single file with all deployment info.
///         Replaces JsonRegistry by consolidating all deployment info into the broadcast directory.
contract DeploymentMetadata is Script {
    string deploymentOutput;
    uint256 registeredContracts;
    uint256 deploymentStartBlock;

    function register(string memory name, address target, string memory version) public {
        string memory contractJson =
            string(abi.encodePacked('{ "address": "', vm.toString(target), '", "version": "', version, '" }'));

        string memory entry = string(abi.encodePacked('    "', name, '": ', contractJson));

        deploymentOutput = (registeredContracts == 0)
            ? string(abi.encodePacked(deploymentOutput, entry))
            : string(abi.encodePacked(deploymentOutput, ",\n", entry));

        registeredContracts += 1;
    }

    function initDeploymentMetadata() internal {
        registeredContracts = 0;
        deploymentOutput = '{\n  "contracts": {\n';
        deploymentStartBlock = block.number;
    }

    /// @notice Save deployment metadata alongside the Forge broadcast output.
    ///         Must be called after vm.stopBroadcast().
    /// @param scriptName The script filename (e.g., "LaunchDeployer.s.sol")
    function saveDeploymentMetadata(string memory scriptName) internal {
        string memory blockJson;
        if (deploymentStartBlock > 0) {
            blockJson = string(
                abi.encodePacked(
                    '\n  },\n  "deploymentStartBlock": "', vm.toString(deploymentStartBlock), '"\n}'
                )
            );
        } else {
            blockJson = "\n  }\n}";
        }

        string memory fullOutput = string(abi.encodePacked(deploymentOutput, blockJson));

        // Write to broadcast/<scriptName>/<chainId>/deployment-metadata.json
        string memory dir =
            string(abi.encodePacked("./broadcast/", scriptName, "/", vm.toString(block.chainid), "/"));
        if (!vm.exists(dir)) {
            vm.createDir(dir, true);
        }

        string memory metadataPath = string(abi.encodePacked(dir, "deployment-metadata.json"));
        vm.writeFile(metadataPath, fullOutput);
        console.log("Deployment metadata saved to: %s", metadataPath);
    }
}
