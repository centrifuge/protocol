// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "../src/core/messaging/interfaces/IAdapter.sol";

import {IOpsGuardian} from "../src/admin/interfaces/IOpsGuardian.sol";

import "forge-std/Script.sol";

/// @dev Configures the local network's adapters to communicate with remote networks.
///      This script only sets up one-directional communication (local → remote).
///      For bidirectional communication, the script must be run on each network separately.
///
///      Intended for testnet use only.
contract WireAdapters is Script {
    IAdapter[] adapters; // Storage array for adapter instances
    address private localWormholeAddr;
    address private localLayerZeroAddr;
    address private localAxelarAddr;

    function _maybeAddLocalAdapter(
        string memory localConfig,
        string memory jsonPath,
        string memory adapterLabel,
        string memory localNetwork
    ) private returns (address addr) {
        addr = address(0);
        try vm.parseJsonAddress(localConfig, jsonPath) returns (address parsed) {
            if (parsed != address(0)) {
                adapters.push(IAdapter(parsed));
                return parsed;
            } else {
                console.log("No", adapterLabel, "found (zero) in config for", localNetwork);
                return address(0);
            }
        } catch {
            console.log("No", adapterLabel, "found in config for network", localNetwork);
            return address(0);
        }
    }

    function _wireWormhole(
        string memory remoteNetwork,
        string memory remoteConfig,
        IOpsGuardian opsGuardian
    ) private {
        string memory localNetwork = vm.envString("NETWORK");
        if (localWormholeAddr == address(0)) {
            console.log("Skipping Wormhole: local adapter not present on", localNetwork);
            return;
        }
        bool remoteDeploy = false;
        try vm.parseJsonBool(remoteConfig, "$.adapters.wormhole.deploy") returns (bool value) {
            remoteDeploy = value;
        } catch {
            console.log("Skipping Wormhole to", remoteNetwork, ": missing $.adapters.wormhole.deploy in remote config");
            return;
        }
        if (!remoteDeploy) {
            console.log("Skipping Wormhole to", remoteNetwork, ": remote deploy flag is false");
            return;
        }
        address remoteAdapter;
        uint16 remoteId;
        bool ok = true;
        try vm.parseJsonAddress(remoteConfig, "$.contracts.wormholeAdapter") returns (address addr) {
            remoteAdapter = addr;
        } catch {
            ok = false;
            console.log("Skipping Wormhole to", remoteNetwork, ": missing $.contracts.wormholeAdapter in remote config");
        }
        try vm.parseJsonUint(remoteConfig, "$.adapters.wormhole.wormholeId") returns (uint256 id) {
            remoteId = uint16(id);
        } catch {
            ok = false;
            console.log("Skipping Wormhole to", remoteNetwork, ": missing $.adapters.wormhole.wormholeId in remote config");
        }
        if (!ok) return;
        if (remoteAdapter == address(0)) {
            console.log("Skipping Wormhole to", remoteNetwork, ": remote adapter address is zero");
            return;
        }
        uint16 remoteCentrifugeId = uint16(vm.parseJsonUint(remoteConfig, "$.network.centrifugeId"));
        bytes memory data = abi.encode(remoteId, remoteAdapter);
        opsGuardian.wire(localWormholeAddr, remoteCentrifugeId, data);
        console.log("Wired WormholeAdapter from", localNetwork, "to", remoteNetwork);
    }

    function _wireLayerZero(
        string memory remoteNetwork,
        string memory remoteConfig,
        IOpsGuardian opsGuardian
    ) private {
        string memory localNetwork = vm.envString("NETWORK");
        if (localLayerZeroAddr == address(0)) {
            console.log("Skipping LayerZero: local adapter not present on", localNetwork);
            return;
        }
        bool remoteDeploy = false;
        try vm.parseJsonBool(remoteConfig, "$.adapters.layerZero.deploy") returns (bool value) {
            remoteDeploy = value;
        } catch {
            console.log("Skipping LayerZero to", remoteNetwork, ": missing $.adapters.layerZero.deploy in remote config");
            return;
        }
        if (!remoteDeploy) {
            console.log("Skipping LayerZero to", remoteNetwork, ": remote deploy flag is false");
            return;
        }
        address remoteAdapter;
        uint32 remoteEid;
        bool ok = true;
        try vm.parseJsonAddress(remoteConfig, "$.contracts.layerZeroAdapter") returns (address addr) {
            remoteAdapter = addr;
        } catch {
            ok = false;
            console.log("Skipping LayerZero to", remoteNetwork, ": missing $.contracts.layerZeroAdapter in remote config");
        }
        try vm.parseJsonUint(remoteConfig, "$.adapters.layerZero.layerZeroEid") returns (uint256 eid) {
            remoteEid = uint32(eid);
        } catch {
            ok = false;
            console.log("Skipping LayerZero to", remoteNetwork, ": missing $.adapters.layerZero.layerZeroEid in remote config");
        }
        if (!ok) return;
        if (remoteAdapter == address(0)) {
            console.log("Skipping LayerZero to", remoteNetwork, ": remote adapter address is zero");
            return;
        }
        uint16 remoteCentrifugeId = uint16(vm.parseJsonUint(remoteConfig, "$.network.centrifugeId"));
        bytes memory data = abi.encode(remoteEid, remoteAdapter);
        opsGuardian.wire(localLayerZeroAddr, remoteCentrifugeId, data);
        console.log("Wired LayerZeroAdapter from", localNetwork, "to", remoteNetwork);
    }

    function _wireAxelar(
        string memory remoteNetwork,
        string memory remoteConfig,
        IOpsGuardian opsGuardian
    ) private {
        string memory localNetwork = vm.envString("NETWORK");
        if (localAxelarAddr == address(0)) {
            console.log("Skipping Axelar: local adapter not present on", localNetwork);
            return;
        }
        bool remoteDeploy = false;
        try vm.parseJsonBool(remoteConfig, "$.adapters.axelar.deploy") returns (bool value) {
            remoteDeploy = value;
        } catch {
            console.log("Skipping Axelar to", remoteNetwork, ": missing $.adapters.axelar.deploy in remote config");
            return;
        }
        if (!remoteDeploy) {
            console.log("Skipping Axelar to", remoteNetwork, ": remote deploy flag is false");
            return;
        }
        string memory remoteAxelarId;
        address remoteAdapter;
        bool ok = true;
        try vm.parseJsonString(remoteConfig, "$.adapters.axelar.axelarId") returns (string memory axelarId) {
            remoteAxelarId = axelarId;
        } catch {
            ok = false;
            console.log("Skipping Axelar to", remoteNetwork, ": missing $.adapters.axelar.axelarId in remote config");
        }
        try vm.parseJsonAddress(remoteConfig, "$.contracts.axelarAdapter") returns (address addr) {
            remoteAdapter = addr;
        } catch {
            ok = false;
            console.log("Skipping Axelar to", remoteNetwork, ": missing $.contracts.axelarAdapter in remote config");
        }
        if (!ok) return;
        if (remoteAdapter == address(0)) {
            console.log("Skipping Axelar to", remoteNetwork, ": remote adapter address is zero");
            return;
        }
        uint16 remoteCentrifugeId = uint16(vm.parseJsonUint(remoteConfig, "$.network.centrifugeId"));
        bytes memory data = abi.encode(remoteAxelarId, vm.toString(remoteAdapter));
        opsGuardian.wire(localAxelarAddr, remoteCentrifugeId, data);
        console.log("Wired AxelarAdapter from", localNetwork, "to", remoteNetwork);
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

        // Declare and initialize local adapter addresses via a single helper
        localWormholeAddr = _maybeAddLocalAdapter(localConfig, "$.contracts.wormholeAdapter", "WormholeAdapter", localNetwork);
        localLayerZeroAddr = _maybeAddLocalAdapter(localConfig, "$.contracts.layerZeroAdapter", "LayerZeroAdapter", localNetwork);
        localAxelarAddr = _maybeAddLocalAdapter(localConfig, "$.contracts.axelarAdapter", "AxelarAdapter", localNetwork);

        string[] memory connectsTo = vm.parseJsonStringArray(localConfig, "$.network.connectsTo");
        IOpsGuardian opsGuardian = IOpsGuardian(vm.parseJsonAddress(localConfig, "$.contracts.opsGuardian"));

        vm.startBroadcast();
        for (uint256 i = 0; i < connectsTo.length; i++) {
            string memory remoteNetwork = connectsTo[i];
            string memory remoteConfig = fetchConfig(remoteNetwork);
            uint16 remoteCentrifugeId = uint16(vm.parseJsonUint(remoteConfig, "$.network.centrifugeId"));

            // Register and wire per remote (threshold = adapters.length, recoveryIndex = adapters.length - 1)
            if (adapters.length == 0) {
                console.log("Skipping registration for", remoteNetwork, ": no local adapters present");
            } else {
                uint8 threshold = uint8(adapters.length);
                uint8 recoveryIndex = uint8(adapters.length - 1);
                opsGuardian.initAdapters(remoteCentrifugeId, adapters, threshold, recoveryIndex);
                console.log("Registered MultiAdapter(", localNetwork, ") for", remoteNetwork);
            }

            _wireWormhole(remoteNetwork, remoteConfig, opsGuardian);
            _wireLayerZero(remoteNetwork, remoteConfig, opsGuardian);
            _wireAxelar(remoteNetwork, remoteConfig, opsGuardian);
        }
        vm.stopBroadcast();
    }
}
