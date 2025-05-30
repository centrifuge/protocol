// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {WormholeAdapter} from "src/common/adapters/WormholeAdapter.sol";
import {AxelarAdapter} from "src/common/adapters/AxelarAdapter.sol";
import {MultiAdapter} from "src/common/adapters/MultiAdapter.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";


contract WireAdapters is Script {
    function run() public {
        string memory network1 = vm.envString("NETWORK");
        string memory configFile1 = string.concat("env/", network1, ".json");
        string memory config1 = vm.readFile(configFile1);
        string memory environment = vm.parseJsonString(config1, "$.network.environment");
        uint16 centrifugeId = uint16(vm.parseJsonUint(config1, "$.network.centrifugeId"));
        
        IAdapter[] memory adapters = new IAdapter[];
        bool isTestnet = keccak256(bytes(environment)) == keccak256(bytes("testnet"));
        
        if (!isTestnet) {
            revert("This script is intended for testnet use only");
        }

        try vm.parseJsonAddress(config1, "$.contracts.wormholeAdapter") returns (address wormholeAddr) {
            adapters.push(IAdapter(wormholeAddr));
            wormholeExists = true;
        } catch {
            console.log("No WormholeAdapter found in config for network", network1);
        }

        try vm.parseJsonAddress(config1, "$.contracts.axelarAdapter") returns (address axelarAddr) {
            adapters.push(IAdapter(axelarAddr));
            axelarExists = true;
        } catch {
            console.log("No AxelarAdapter found in config for network", network1);
        }
        string[] memory connectsTo = vm.parseJsonStringArray(
            config1,
            "$.adapters.wormhole.connectsTo"
        );
        vm.startBroadcast();
        for (uint256 i = 0; i < connectsTo.length; i++) {
            string memory network2 = connectsTo[i];
            string memory configFile2 = string.concat("env/",network2,".json");
            string memory config2 = vm.readFile(configFile2);
            uint16 centrifugeId2 = uint16(vm.parseJsonUint(config2, "$.network.centrifugeId"));

            // Register ALL adapters for this destination chain
            MultiAdapter multiAdapter = MultiAdapter(vm.parseJsonAddress(config1, "$.contracts.multiAdapter"));
            multiAdapter.file("adapters", centrifugeId2, adapters);
            console.log("Registered MultiAdapter(", network1, ") for", network2);

            // Wire WormholeAdapter
            if (wormholeExists) {
                uint16 wormholeId2 = uint16(vm.parseJsonUint( config2, "$.adapters.wormhole.chain-id"));
                multiAdapter.file("sources", wormholeId2, centrifugeId2, vm.toString(wormholeAddr));
                multiAdapter.file("destinations", centrifugeId2, wormholeId2, vm.toString(wormholeAddr));
                console.log("Wired WormholeAdapter from", network1, "to", network2);
            }
            // Wire AxelarAdapter
            if (axelarExists) {
                uint16 axelarId2 = uint16(vm.parseJsonUint( config2, "$.adapters.axelar.chain-id"));
                multiAdapter.file("sources", axelarId2, centrifugeId2, vm.toString(axelarAddr));
                multiAdapter.file("destinations", centrifugeId2, axelarId2, vm.toString(axelarAddr));
                console.log("Wired AxelarAdapter from", network1, "to", network2);
            }
        }
        vm.stopBroadcast();
    }
}
