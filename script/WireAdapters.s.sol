// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "../src/core/interfaces/IAdapter.sol";

import {IOpsGuardian} from "../src/admin/interfaces/IOpsGuardian.sol";

import "forge-std/Script.sol";
import "forge-std/console.sol";

/// @dev Configures the local network's adapters to communicate with remote networks.
///      This script only sets up one-directional communication (local → remote).
///      For bidirectional communication, the script must be run on each network separately.
///
///      Intended for testnet use only.
contract WireAdapters is Script {
    // helpers
    function _safeParseBool(string memory json, string memory path) internal view returns (bool b) {
        try vm.parseJsonBool(json, path) returns (bool v) { b = v; } catch { b = false; }
    }

    function _safeParseAddress(string memory json, string memory path) internal view returns (address a) {
        try vm.parseJsonAddress(json, path) returns (address v) { a = v; } catch { a = address(0); }
    }

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

        // Declare local adapter addresses
        address localWormholeAddr = address(0);
        address localLayerZeroAddr = address(0);
        address localAxelarAddr = address(0);

        // Try to get local Wormhole adapter
        try vm.parseJsonAddress(localConfig, "$.contracts.wormholeAdapter") returns (address addr) {
            if (addr != address(0)) {
                localWormholeAddr = addr;
            }
        } catch {
            console.log("No WormholeAdapter found in config for network", localNetwork);
        }

        // Try to get local LayerZero adapter
        try vm.parseJsonAddress(localConfig, "$.contracts.layerZeroAdapter") returns (address addr) {
            if (addr != address(0)) {
                localLayerZeroAddr = addr;
            }
        } catch {
            console.log("No LayerZeroAdapter found in config for network", localNetwork);
        }

        // Try to get local Axelar adapter
        try vm.parseJsonAddress(localConfig, "$.contracts.axelarAdapter") returns (address addr) {
            if (addr != address(0)) {
                localAxelarAddr = addr;
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

            // Determine which adapters are active on BOTH sides
            bool useWH = localWormholeAddr != address(0) && _safeParseBool(remoteConfig, "$.adapters.wormhole.deploy");
            address remoteWH = _safeParseAddress(remoteConfig, "$.contracts.wormholeAdapter");
            if (remoteWH == address(0)) useWH = false;

            bool useLZ = localLayerZeroAddr != address(0) && _safeParseBool(remoteConfig, "$.adapters.layerZero.deploy");
            address remoteLZ = _safeParseAddress(remoteConfig, "$.contracts.layerZeroAdapter");
            if (remoteLZ == address(0)) useLZ = false;

            bool useAX = localAxelarAddr != address(0) && _safeParseBool(remoteConfig, "$.adapters.axelar.deploy");
            address remoteAX = _safeParseAddress(remoteConfig, "$.contracts.axelarAdapter");
            if (remoteAX == address(0)) useAX = false;

            uint8 count;
            if (useWH) count++;
            if (useLZ) count++;
            if (useAX) count++;

            IAdapter[] memory active = new IAdapter[](count);
            uint8 idx;
            if (useWH) active[idx++] = IAdapter(localWormholeAddr);
            if (useLZ) active[idx++] = IAdapter(localLayerZeroAddr);
            if (useAX) active[idx++] = IAdapter(localAxelarAddr);

            // Register ONLY matching adapters for this destination chain
            IOpsGuardian opsGuardian = IOpsGuardian(vm.parseJsonAddress(localConfig, "$.contracts.opsGuardian"));
            if (active.length > 0) {
                opsGuardian.initAdapters(remoteCentrifugeId, active, uint8(active.length), uint8(active.length));
                string memory msg1 = string.concat(
                    "Registered MultiAdapter(",
                    localNetwork,
                    ") for ",
                    remoteNetwork,
                    " with ",
                    vm.toString(active.length),
                    " adapters"
                );
                console.log(msg1);
            } else {
                string memory msg2 = string.concat(
                    "No shared adapters between ", localNetwork, " and ", remoteNetwork, " - skipping registration"
                );
                console.log(msg2);
            }

            // Wire WormholeAdapter
            if (useWH) {
                bytes memory wormholeData = abi.encode(
                    uint16(vm.parseJsonUint(remoteConfig, "$.adapters.wormhole.wormholeId")),
                    remoteWH
                );
                opsGuardian.wire(localWormholeAddr, remoteCentrifugeId, wormholeData);

                console.log("Wired WormholeAdapter from", localNetwork, "to", remoteNetwork);
            }

            // Wire LayerZeroAdapter
            if (useLZ) {
                bytes memory layerZeroData = abi.encode(
                    uint32(vm.parseJsonUint(remoteConfig, "$.adapters.layerZero.layerZeroEid")),
                    remoteLZ
                );
                opsGuardian.wire(localLayerZeroAddr, remoteCentrifugeId, layerZeroData);

                console.log("Wired LayerZeroAdapter from", localNetwork, "to", remoteNetwork);
            }

            // Wire AxelarAdapter
            if (useAX) {
                bytes memory axelarData = abi.encode(
                    vm.parseJsonString(remoteConfig, "$.adapters.axelar.axelarId"),
                    vm.toString(remoteAX)
                );
                opsGuardian.wire(localAxelarAddr, remoteCentrifugeId, axelarData);

                console.log("Wired AxelarAdapter from", localNetwork, "to", remoteNetwork);
            }
        }
        vm.stopBroadcast();
    }
}
