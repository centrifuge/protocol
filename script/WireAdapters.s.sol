// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// NOTE: This script is intended for testnet use only. Do not use in production.

import "forge-std/Script.sol";
import {WormholeAdapter} from "src/common/adapters/WormholeAdapter.sol";
import {AxelarAdapter} from "src/common/adapters/AxelarAdapter.sol";

contract WireAdapters is Script {
    function wireWormholeAdapter(
        string memory network1,
        string memory config1
    ) internal {
        try vm.parseJsonAddress(config1, "$.contracts.wormholeAdapter") returns (address adapter1) {
            if (adapter1 == address(0)) {
                console.log("WormholeAdapter not deployed on network", network1);
                return;
            }
            string[] memory connectsTo = vm.parseJsonStringArray(
                config1,
                "$.adapters.wormhole.connectsTo"
            );
            for (uint256 i = 0; i < connectsTo.length; i++) {
                string memory network2 = connectsTo[i];
                string memory configFile2 = string.concat(
                    "env/",
                    network2,
                    ".json"
                );
                string memory config2 = vm.readFile(configFile2);
                
                try vm.parseJsonAddress(config2, "$.contracts.wormholeAdapter") returns (address adapter2) {
                    if (adapter2 == address(0)) {
                        console.log("WormholeAdapter not deployed on network", network2);
                        continue;
                    }
                    uint16 centrifugeId2 = uint16(
                        vm.parseJsonUint(config2, "$.network.centrifugeId")
                    );
                    uint16 wormholeId2 = uint16(
                        vm.parseJsonUint(
                            config2,
                            "$.adapters.wormhole.chain-id"
                        )
                    );
                    vm.startBroadcast();
                    WormholeAdapter w1 = WormholeAdapter(adapter1);
                    w1.file("sources", centrifugeId2, wormholeId2, adapter2);
                    w1.file(
                        "destinations",
                        centrifugeId2,
                        wormholeId2,
                        adapter2
                    );
                    vm.stopBroadcast();
                    console.log(
                        "Wired WormholeAdapter from",
                        network1,
                        "to",
                        network2
                    );
                } catch {
                    console.log(
                        "No WormholeAdapter found in config for network",
                        network2
                    );
                }
            }
        } catch {
            console.log(
                "No WormholeAdapter found in config for network",
                network1
            );
        }
    }

    function wireAxelarAdapter(
        string memory network1,
        string memory config1
    ) internal {
        try vm.parseJsonAddress(config1, "$.contracts.axelarAdapter") returns (address axelar1) {
            if (axelar1 == address(0)) {
                console.log("AxelarAdapter not deployed on network", network1);
                return;
            }
            string[] memory connectsTo = vm.parseJsonStringArray(
                config1,
                "$.adapters.axelar.connectsTo"
            );
            for (uint256 i = 0; i < connectsTo.length; i++) {
                string memory network2 = connectsTo[i];
                string memory configFile2 = string.concat(
                    "env/",
                    network2,
                    ".json"
                );
                string memory config2 = vm.readFile(configFile2);
                
                try vm.parseJsonAddress(config2, "$.contracts.axelarAdapter") returns (address axelar2) {
                    if (axelar2 == address(0)) {
                        console.log("AxelarAdapter not deployed on network", network2);
                        continue;
                    }
                    string memory axelarId2 = vm.parseJsonString(
                        config2,
                        "$.adapters.axelar.chain-id"
                    );
                    uint16 centrifugeId2 = uint16(
                        vm.parseJsonUint(config2, "$.network.centrifugeId")
                    );
                    AxelarAdapter a1 = AxelarAdapter(axelar1);
                    vm.startBroadcast();
                    a1.file(
                        "sources",
                        axelarId2,
                        centrifugeId2,
                        vm.toString(axelar2)
                    );
                    a1.file(
                        "destinations",
                        centrifugeId2,
                        axelarId2,
                        vm.toString(axelar2)
                    );
                    vm.stopBroadcast();
                    console.log(
                        "Wired AxelarAdapter from",
                        network1,
                        "to",
                        network2
                    );
                } catch {
                    console.log(
                        "No AxelarAdapter found in config for network",
                        network2
                    );
                }
            }
        } catch {
            console.log("No AxelarAdapter found in network", network1);
        }
    }

    function run() public {
        string memory network1 = vm.envString("NETWORK");
        string memory configFile1 = string.concat("env/", network1, ".json");
        string memory config1 = vm.readFile(configFile1);

        wireWormholeAdapter(network1, config1);
        wireAxelarAdapter(network1, config1);
    }
}
