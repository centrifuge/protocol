// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {Root} from "src/common/Root.sol";
import {MultiAdapter} from "src/common/adapters/MultiAdapter.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {WormholeAdapter} from "src/common/adapters/WormholeAdapter.sol";
import {AxelarAdapter} from "src/common/adapters/AxelarAdapter.sol";
import {JsonRegistry} from "script/utils/JsonRegistry.s.sol";

contract Adapters is Script, JsonRegistry {
    // Common contract addresses
    Root public root;
    MultiAdapter public multiAdapter;
    IAdapter[] public adapters;

    function run() public {
        // Read and parse JSON configuration
        string memory network = vm.envString("NETWORK");
        string memory configFile = string.concat("env/", network, ".json");
        string memory config = vm.readFile(configFile);
        uint16 centrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));
        string memory environment = vm.parseJsonString(config, "$.network.environment");
        bool isTestnet = keccak256(bytes(environment)) == keccak256(bytes("testnet"));
        
        console.log("Environment:", environment);
        console.log("Is testnet:", isTestnet);
        
        root = Root(vm.parseJsonAddress(config, "$.contracts.root"));
        multiAdapter = MultiAdapter(vm.parseJsonAddress(config, "$.contracts.multiAdapter"));
        
        vm.startBroadcast();
        startDeploymentOutput(false);

        // Deploy and save adapters for wiring
        if (vm.parseJsonBool(config, "$.adapters.wormhole.deploy")) {
            address relayer = vm.parseJsonAddress(config, "$.adapters.wormhole.relayer");
            WormholeAdapter wormholeAdapter = new WormholeAdapter(
                multiAdapter,
                relayer,
                msg.sender
            );
            adapters.push(wormholeAdapter);
            register("wormholeAdapter", address(wormholeAdapter));
            console.log("WormholeAdapter deployed at:", address(wormholeAdapter));
        }

        if (vm.parseJsonBool(config, "$.adapters.axelar.deploy")) {
            address gateway = vm.parseJsonAddress(config, "$.adapters.axelar.gateway");
            address gasService = vm.parseJsonAddress(config, "$.adapters.axelar.gasService");
            AxelarAdapter axelarAdapter = new AxelarAdapter(
                multiAdapter,
                gateway,
                gasService,
                msg.sender
            );
            adapters.push(axelarAdapter);
            register("axelarAdapter", address(axelarAdapter));
            console.log("AxelarAdapter deployed at:", address(axelarAdapter));
        }

        // Register all adapters at once
        if (adapters.length > 0) {
            console.log("Registering adapters...");
            multiAdapter.file("adapters", centrifugeId, adapters);
            for (uint256 i = 0; i < adapters.length; i++) {
                console.log("Processing adapter:", address(adapters[i]));
                IAuth(address(adapters[i])).rely(address(root));
                
                // Only deny msg.sender if not on testnet
                if (!isTestnet) {
                    IAuth(address(adapters[i])).deny(msg.sender);
                }
            }
        }
        
        saveDeploymentOutput(); // Save JSON output
        vm.stopBroadcast();
    }
}
