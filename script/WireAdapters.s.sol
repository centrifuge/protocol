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
            wireWormholeAdapter(network1, config1);
        
        } catch {
            console.log("No WormholeAdapter found in config for network", network1);
        }

        try vm.parseJsonAddress(config1, "$.contracts.axelarAdapter") returns (address axelarAddr) {
            adapters.push(IAdapter(axelarAddr));
            wireAxelarAdapter(network1, config1);
        } catch {
            console.log("No AxelarAdapter found in config for network", network1);
        }

        MultiAdapter multiAdapter = MultiAdapter(vm.parseJsonAddress(config1, "$.contracts.multiAdapter"));
        vm.startBroadcast();
        multiAdapter.file("adapters", centrifugeId, adapters);
        vm.stopBroadcast();
    }

    function wireWormholeAdapter(string memory network1,string memory config1) internal {

        string[] memory connectsTo = vm.parseJsonStringArray(
            config1,
            "$.adapters.wormhole.connectsTo"
        );
        for (uint256 i = 0; i < connectsTo.length; i++) {
            string memory network2 = connectsTo[i];
            string memory configFile2 = string.concat("env/",network2,".json");
            string memory config2 = vm.readFile(configFile2);
            
            try vm.parseJsonAddress(config2, "$.contracts.wormholeAdapter") returns (address adapter2) {
                uint16 centrifugeId2 = uint16(vm.parseJsonUint(config2, "$.network.centrifugeId"));
                uint16 wormholeId2 = uint16(vm.parseJsonUint( config2, "$.adapters.wormhole.chain-id"));
                vm.startBroadcast();
                WormholeAdapter adapter1 = WormholeAdapter(
                    vm.parseJsonAddress(config1, 
                    "$.contracts.wormholeAdapter"));
                adapter1.file("sources", wormholeId2, centrifugeId2, vm.toString(adapter2));
                adapter1.file("destinations", centrifugeId2, wormholeId2, vm.toString(adapter2));
                vm.stopBroadcast();
                console.log("Wired WormholeAdapter from", network1, "to", network);
            } catch {
                console.log("No WormholeAdapter found in config for network", network2);
            }
        }

    }

    function wireAxelarAdapter(
        string memory network1,
        string memory config1
    ) internal {
        string[] memory connectsTo = vm.parseJsonStringArray(
            config1,
            "$.adapters.axelar.connectsTo"
        );
        for (uint256 i = 0; i < connectsTo.length; i++) {
            string memory network2 = connectsTo[i];
            string memory configFile2 = string.concat("env/",network2,".json");
            string memory config2 = vm.readFile(configFile2);
            
            try vm.parseJsonAddress(config2, "$.contracts.axelarAdapter") returns (address axelar2) {
                string memory axelarId2 = vm.parseJsonString(config2, "$.adapters.axelar.chain-id");
                uint16 centrifugeId2 = uint16(vm.parseJsonUint(config2, "$.network.centrifugeId"));
                AxelarAdapter adapter1 = AxelarAdapter(
                    vm.parseJsonAddress(config1, 
                    "$.contracts.axelarAdapter"));
                vm.startBroadcast();
                adapter1.file( "sources", axelarId2, centrifugeId2, vm.toString(axelar2) );
                adapter1.file( "destinations", centrifugeId2, axelarId2, vm.toString(axelar2)                    ) 
                vm.stopBroadcast();
                console.log( "Wired AxelarAdapter from", network1, "to", network2 );
            } catch {
                console.log("No AxelarAdapter found in config for network",network2);
            }
        }
        
    }

}
