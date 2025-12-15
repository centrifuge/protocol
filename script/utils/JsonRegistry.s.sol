// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract JsonRegistry is Script {
    string deploymentOutput;
    uint256 registeredContracts = 0;
    bool shouldLabelAddresses;
    string addressLabelPrefix;
    uint256 deploymentStartBlock;
    uint256 deploymentEndBlock;

    function register(string memory name, address target) public {
        // Note: Real block numbers are extracted from broadcast artifacts by verifier.py
        // block.number here would be the script execution block, not the actual deployment block
        string memory contractJson = string(abi.encodePacked('    "', name, '": "', vm.toString(target), '"'));

        deploymentOutput = (registeredContracts == 0)
            ? string(abi.encodePacked(deploymentOutput, contractJson))
            : string(abi.encodePacked(deploymentOutput, ",\n", contractJson));

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

    function captureStartBlock() public {
        deploymentStartBlock = block.number;
    }

    function captureEndBlock() public {
        deploymentEndBlock = block.number;
    }

    function saveDeploymentOutput() public {
        string memory dir = "./env/latest/";
        if (!vm.exists(dir)) {
            vm.createDir(dir, true);
        }

        // Add deployment block range to output if captured
        string memory blockRangeJson = "";
        if (deploymentStartBlock > 0 && deploymentEndBlock > 0) {
            blockRangeJson = string(
                abi.encodePacked(
                    "\n  },\n  \"deploymentBlocks\": {\n",
                    "    \"startBlock\": \"",
                    vm.toString(deploymentStartBlock),
                    "\",\n",
                    "    \"endBlock\": \"",
                    vm.toString(deploymentEndBlock),
                    "\"\n",
                    "  }\n}"
                )
            );
        } else {
            blockRangeJson = "\n  }\n}";
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
        string memory fullOutput = string(abi.encodePacked(deploymentOutput, blockRangeJson));
        vm.writeFile(timestampedPath, fullOutput);
        console.log("Contract addresses saved to: %s", timestampedPath);

        // Save as latest
        string memory latestPath = string(abi.encodePacked(dir, vm.toString(block.chainid), "-latest.json"));

        vm.writeFile(latestPath, fullOutput);
        console.log("Contract addresses also saved to: %s", latestPath);
    }

    /// @notice Read a contract address from JSON config, supporting both nested and flat formats
    /// @dev Tries to read from "pointer.address" first, falls back to "pointer" directly
    /// @param config The JSON configuration string
    /// @param pointer The JSON path to the contract address (e.g., "$.contracts.hub")
    /// @return The contract address
    function _readContractAddress(string memory config, string memory pointer) internal pure returns (address) {
        string memory nestedPointer = string.concat(pointer, ".address");
        try vm.parseJsonAddress(config, nestedPointer) returns (address addr) {
            if (addr != address(0)) {
                return addr;
            }
        } catch {}
        return vm.parseJsonAddress(config, pointer);
    }
}
