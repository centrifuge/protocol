// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "../src/core/interfaces/IAdapter.sol";

import {IOpsGuardian} from "../src/admin/interfaces/IOpsGuardian.sol";

import "forge-std/Script.sol";

/// @dev Configures the local network's adapters to communicate with remote networks.
///      This script only sets up one-directional communication (local → remote).
///      For bidirectional communication, the script must be run on each network separately.
///
///      Intended for testnet use only.
contract WireAdapters is Script {
    IAdapter[] adapters; // Storage array for adapter instances

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
        string memory localNetwork = vm.envString("NETWORK");
        string memory localConfig = fetchConfig(localNetwork);

        // Declare and initialize local adapter addresses
        address localWormholeAddr = address(0);
        address localLayerZeroAddr = address(0);
        address localAxelarAddr = address(0);

        // Try to get local Wormhole adapter
        try vm.parseJsonAddress(localConfig, "$.contracts.wormholeAdapter") returns (address addr) {
            if (addr != address(0)) {
                localWormholeAddr = addr;
                adapters.push(IAdapter(addr));
            }
        } catch {
            console.log("No WormholeAdapter found in config for network", localNetwork);
        }

        // Try to get local LayerZero adapter
        try vm.parseJsonAddress(localConfig, "$.contracts.layerZeroAdapter") returns (address addr) {
            if (addr != address(0)) {
                localLayerZeroAddr = addr;
                adapters.push(IAdapter(addr));
            }
        } catch {
            console.log("No LayerZeroAdapter found in config for network", localNetwork);
        }

        // Try to get local Axelar adapter
        try vm.parseJsonAddress(localConfig, "$.contracts.axelarAdapter") returns (address addr) {
            if (addr != address(0)) {
                localAxelarAddr = addr;
                adapters.push(IAdapter(addr));
            }
        } catch {
            console.log("No AxelarAdapter found in config for network", localNetwork);
        }

        string[] memory connectsTo = vm.parseJsonStringArray(localConfig, "$.network.connectsTo");

        vm.startBroadcast();
        for (uint256 i = 0; i < connectsTo.length; i++) {
            string memory remoteNetwork = connectsTo[i];
            string memory remoteConfig = fetchConfig(remoteNetwork);
            uint16 remoteCentrifugeId = uint16(vm.parseJsonUint(remoteConfig, "$.network.centrifugeId"));

            // Register ALL adapters for this destination chain
            IOpsGuardian opsGuardian = IOpsGuardian(vm.parseJsonAddress(localConfig, "$.contracts.opsGuardian"));
            opsGuardian.initAdapters(remoteCentrifugeId, adapters, uint8(adapters.length), uint8(adapters.length));
            console.log("Registered MultiAdapter(", localNetwork, ") for", remoteNetwork);

        // Wire WormholeAdapter (only if both sides have it and remote deploy flag is true)
        if (localWormholeAddr != address(0)) {
            bool remoteWormholeDeploy = false;
            try vm.parseJsonBool(remoteConfig, "$.adapters.wormhole.deploy") returns (bool value) {
                remoteWormholeDeploy = value;
            } catch {}
            if (remoteWormholeDeploy) {
                bytes memory wormholeData = abi.encode(
                    uint16(vm.parseJsonUint(remoteConfig, "$.adapters.wormhole.wormholeId")),
                    vm.parseJsonAddress(remoteConfig, "$.contracts.wormholeAdapter")
                );
                opsGuardian.wire(localWormholeAddr, remoteCentrifugeId, wormholeData);

                console.log("Wired WormholeAdapter from", localNetwork, "to", remoteNetwork);
            }
            }

        // Wire LayerZeroAdapter (only if both sides have it and remote deploy flag is true)
        if (localLayerZeroAddr != address(0)) {
            bool remoteLayerZeroDeploy = false;
            try vm.parseJsonBool(remoteConfig, "$.adapters.layerZero.deploy") returns (bool value) {
                remoteLayerZeroDeploy = value;
            } catch {}
            if (remoteLayerZeroDeploy) {
                bytes memory layerZeroData = abi.encode(
                    uint32(vm.parseJsonUint(remoteConfig, "$.adapters.layerZero.layerZeroEid")),
                    vm.parseJsonAddress(remoteConfig, "$.contracts.layerZeroAdapter")
                );
                opsGuardian.wire(localLayerZeroAddr, remoteCentrifugeId, layerZeroData);

                console.log("Wired LayerZeroAdapter from", localNetwork, "to", remoteNetwork);
            }
            }

        // Wire AxelarAdapter (only if both sides have it and remote deploy flag is true)
        if (localAxelarAddr != address(0)) {
            bool remoteAxelarDeploy = false;
            try vm.parseJsonBool(remoteConfig, "$.adapters.axelar.deploy") returns (bool value) {
                remoteAxelarDeploy = value;
            } catch {}
            if (remoteAxelarDeploy) {
                bytes memory axelarData = abi.encode(
                    vm.parseJsonString(remoteConfig, "$.adapters.axelar.axelarId"),
                    vm.toString(vm.parseJsonAddress(remoteConfig, "$.contracts.axelarAdapter"))
                );
                opsGuardian.wire(localAxelarAddr, remoteCentrifugeId, axelarData);

                console.log("Wired AxelarAdapter from", localNetwork, "to", remoteNetwork);
            }
            }
        }
        vm.stopBroadcast();
    }
}
