// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {WormholeAdapter} from "src/common/adapters/WormholeAdapter.sol";
import {AxelarAdapter} from "src/common/adapters/AxelarAdapter.sol";
import {MultiAdapter} from "src/common/adapters/MultiAdapter.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";

// NOTE: Assumes each adapter in network A is also set up in network B, and all adapters should be wired
contract WireAdapters is Script {
    IAdapter[] adapters; // Storage array like in CommonDeployer

    function fetchConfig(string memory network) internal view returns (string memory) {
        string memory configFile = string.concat("env/", network, ".json");
        string memory config = vm.readFile(configFile);

        string memory environment = vm.parseJsonString(config, "$.network.environment");
        if (keccak256(bytes(environment)) != keccak256(bytes("testnet"))) {
            revert("This script is intended for testnet use only");
        }

        return config;
    }

    function run() public {
        string memory network1 = vm.envString("NETWORK");
        string memory config1 = fetchConfig(network1);

        // Declare and initialize adapter addresses
        address wormholeAddr = address(0);
        address axelarAddr = address(0);

        // Try to get Wormhole adapter
        try vm.parseJsonAddress(config1, "$.contracts.wormholeAdapter") returns (address addr) {
            if (addr != address(0)) {
                wormholeAddr = addr;
                adapters.push(IAdapter(addr));
            }
        } catch {
            console.log("No WormholeAdapter found in config for network", network1);
        }

        // Try to get Axelar adapter
        try vm.parseJsonAddress(config1, "$.contracts.axelarAdapter") returns (address addr) {
            if (addr != address(0)) {
                axelarAddr = addr;
                adapters.push(IAdapter(addr));
            }
        } catch {
            console.log("No AxelarAdapter found in config for network", network1);
        }

        string[] memory connectsTo = vm.parseJsonStringArray(config1, "$.network.connectsTo");

        vm.startBroadcast();
        for (uint256 i = 0; i < connectsTo.length; i++) {
            string memory network2 = connectsTo[i];
            string memory config2 = fetchConfig(network2);
            uint16 centrifugeId2 = uint16(vm.parseJsonUint(config2, "$.network.centrifugeId"));

            // Register ALL adapters for this destination chain
            MultiAdapter multiAdapter = MultiAdapter(vm.parseJsonAddress(config1, "$.contracts.multiAdapter"));
            multiAdapter.file("adapters", centrifugeId2, adapters);
            console.log("Registered MultiAdapter(", network1, ") for", network2);

            // Wire WormholeAdapter
            if (wormholeAddr != address(0)) {
                address wormholeAddr2 = vm.parseJsonAddress(config2, "$.contracts.wormholeAdapter");
                uint16 wormholeId2 = uint16(vm.parseJsonUint(config2, "$.adapters.wormhole.wormholeId"));

                WormholeAdapter wormholeAdapter = WormholeAdapter(wormholeAddr);
                wormholeAdapter.file("sources", centrifugeId2, wormholeId2, wormholeAddr2);
                wormholeAdapter.file("destinations", centrifugeId2, wormholeId2, wormholeAddr2);

                console.log("Wired WormholeAdapter from", network1, "to", network2);
            }

            // Wire AxelarAdapter
            if (axelarAddr != address(0)) {
                address axelarAddr2 = vm.parseJsonAddress(config2, "$.contracts.axelarAdapter");
                string memory axelarId2 = vm.parseJsonString(config2, "$.adapters.axelar.axelarId");

                AxelarAdapter axelarAdapter = AxelarAdapter(axelarAddr);
                axelarAdapter.file("sources", axelarId2, centrifugeId2, vm.toString(axelarAddr2));
                axelarAdapter.file("destinations", centrifugeId2, axelarId2, vm.toString(axelarAddr2));

                console.log("Wired AxelarAdapter from", network1, "to", network2);
            }
        }
        vm.stopBroadcast();
    }
}
