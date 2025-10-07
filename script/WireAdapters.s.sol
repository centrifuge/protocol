// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "../src/core/interfaces/IAdapter.sol";

import {IGuardian} from "../src/admin/interfaces/IGuardian.sol";

import "forge-std/Script.sol";

import {IAxelarAdapter} from "../src/adapters/interfaces/IAxelarAdapter.sol";
import {IWormholeAdapter} from "../src/adapters/interfaces/IWormholeAdapter.sol";
import {ILayerZeroAdapter} from "../src/adapters/interfaces/ILayerZeroAdapter.sol";

/// @dev Configures the local network's adapters to communicate with remote networks.
///      This script only sets up one-directional communication (local → remote).
///      For bidirectional communication, the script must be run on each network separately.
///
///      Intended for testnet use only.
contract WireAdapters is Script {
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

            // Build per-destination adapter set, excluding adapters not deployed on remote
            IAdapter[] memory temp = new IAdapter[](3);
            uint8 count = 0;

            bool remoteWormhole = false;
            bool remoteLayerZero = false;
            bool remoteAxelar = false;

            try vm.parseJsonBool(remoteConfig, "$.adapters.wormhole.deploy") returns (bool dep) {
                remoteWormhole = dep;
            } catch {}
            try vm.parseJsonBool(remoteConfig, "$.adapters.layerZero.deploy") returns (bool dep) {
                remoteLayerZero = dep;
            } catch {}
            try vm.parseJsonBool(remoteConfig, "$.adapters.axelar.deploy") returns (bool dep) {
                remoteAxelar = dep;
            } catch {}

            if (localWormholeAddr != address(0) && remoteWormhole) {
                temp[count++] = IAdapter(localWormholeAddr);
            }
            if (localLayerZeroAddr != address(0) && remoteLayerZero) {
                temp[count++] = IAdapter(localLayerZeroAddr);
            }
            if (localAxelarAddr != address(0) && remoteAxelar) {
                temp[count++] = IAdapter(localAxelarAddr);
            }

            IAdapter[] memory adaptersForDst = new IAdapter[](count);
            for (uint8 j = 0; j < count; j++) adaptersForDst[j] = temp[j];

            // Register destination's adapter set through Guardian (GLOBAL for that dst)
            IGuardian guardian = IGuardian(vm.parseJsonAddress(localConfig, "$.contracts.guardian"));
            // threshold = max(1, count). Use 1 so any adapter can deliver by default.
            uint8 threshold = count == 0 ? 0 : 1;
            uint8 recoveryIndex = count; // not used when threshold=1
            if (count > 0) {
                guardian.setAdapters(remoteCentrifugeId, adaptersForDst, count, threshold);
                console.log("Registered MultiAdapter(", localNetwork, ") for", remoteNetwork, "with", count, "adapters");
            } else {
                console.log("Skipping registration for", remoteNetwork, "(no common adapters)");
            }

            // Wire WormholeAdapter when present on both ends
            if (localWormholeAddr != address(0) && remoteWormhole) {
                IWormholeAdapter(localWormholeAddr).wire(
                    remoteCentrifugeId,
                    uint16(vm.parseJsonUint(remoteConfig, "$.adapters.wormhole.wormholeId")),
                    vm.parseJsonAddress(remoteConfig, "$.contracts.wormholeAdapter")
                );
                console.log("Wired WormholeAdapter from", localNetwork, "to", remoteNetwork);
            }

            // Wire LayerZeroAdapter when present on both ends
            if (localLayerZeroAddr != address(0) && remoteLayerZero) {
                ILayerZeroAdapter(localLayerZeroAddr).wire(
                    remoteCentrifugeId,
                    uint32(vm.parseJsonUint(remoteConfig, "$.adapters.layerZero.layerZeroEid")),
                    vm.parseJsonAddress(remoteConfig, "$.contracts.layerZeroAdapter")
                );
                console.log("Wired LayerZeroAdapter from", localNetwork, "to", remoteNetwork);
            }

            // Wire AxelarAdapter when present on both ends
            if (localAxelarAddr != address(0) && remoteAxelar) {
                IAxelarAdapter(localAxelarAddr).wire(
                    remoteCentrifugeId,
                    vm.parseJsonString(remoteConfig, "$.adapters.axelar.axelarId"),
                    vm.toString(vm.parseJsonAddress(remoteConfig, "$.contracts.axelarAdapter"))
                );
                console.log("Wired AxelarAdapter from", localNetwork, "to", remoteNetwork);
            }
        }
        vm.stopBroadcast();
    }
}
