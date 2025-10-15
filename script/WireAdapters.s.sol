// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "../src/core/messaging/interfaces/IAdapter.sol";

import {IProtocolGuardian} from "../src/admin/interfaces/IProtocolGuardian.sol";

import "forge-std/Script.sol";

/// @title WireAdapters
/// @notice Configures the source network's adapters to communicate with destination networks.
/// @dev This script sets up one-directional communication (source → destination).
///      For bidirectional communication, the script must be run on each network separately.
///      
///      The script enforces symmetric adapter configuration:
///      - Only registers adapters that exist on BOTH source and destination networks
///      - Only wires adapters that are configured for the destination network
///      - Prevents InvalidAdapter errors from asymmetric configurations
///
///      Intended for testnet use only.
contract WireAdapters is Script {
    address private localWormholeAddr;  // Source Wormhole adapter address (if deployed)
    address private localLayerZeroAddr; // Source LayerZero adapter address (if deployed)
    address private localAxelarAddr;    // Source Axelar adapter address (if deployed)

    /// @notice Detects and stores local adapter addresses from local network config
    /// @dev Checks if adapter is marked for deployment and the address exists
    /// @return addr The adapter address if found, address(0) if not found
    function _maybeAddLocalAdapter(
        string memory config,
        string memory adapterLabel,
        string memory network
    ) private pure returns (address addr) {
        string memory contractJsonPath;
        string memory deployJsonPath;

        // String comparisons in Solidity require keccak256, not ==
        if (keccak256(bytes(adapterLabel)) == keccak256(bytes("WormholeAdapter"))) {
            contractJsonPath = "$.contracts.wormholeAdapter";
            deployJsonPath = "$.adapters.wormhole.deploy";
        } else if (keccak256(bytes(adapterLabel)) == keccak256(bytes("LayerZeroAdapter"))) {
            contractJsonPath = "$.contracts.layerZeroAdapter";
            deployJsonPath = "$.adapters.layerZero.deploy";
        } else if (keccak256(bytes(adapterLabel)) == keccak256(bytes("AxelarAdapter"))) {
            contractJsonPath = "$.contracts.axelarAdapter";
            deployJsonPath = "$.adapters.axelar.deploy";
        } else {
            // Unknown adapter label
            console.log("Unknown adapter label:", adapterLabel);
            return address(0);
        }

        addr = address(0);
        bool deploy;

        // parseJsonBool may revert, so we wrap in try-catch
        try vm.parseJsonBool(config, deployJsonPath) returns (bool parsedDeploy) {
            deploy = parsedDeploy;
        } catch {
            // treat as not deployed if key not found
            deploy = false;
            console.log( adapterLabel, "not configured to be deployed on", network);
            console.log("Skipping", adapterLabel);
            return address(0);
        }
        // parseJsonAddress may revert, so wrap in try-catch
        try vm.parseJsonAddress(config, contractJsonPath) returns (address parsedAddr) {
            if (parsedAddr != address(0)) {
                return parsedAddr;
            } else { 
                console.log("Unexpected:", adapterLabel, "is zero in config for", network);
            }
        } catch {
            console.log("No", adapterLabel, "found in config for network", network);
            return address(0);
        }
    }

    uint8 constant GAS_MULTIPLIER = 10; // 10%

    function fetchConfig(string memory network) internal view returns (string memory) {
        string memory configFile = string.concat("env/", network, ".json");
        string memory config = vm.readFile(configFile);

        string memory environment = vm.parseJsonString(config, "$.network.environment");
        if (keccak256(bytes(environment)) != keccak256(bytes("testnet"))) {
            revert("This script is intended for testnet use only");
        }

        return config;
    }

    /// @notice Main function that configures adapters for all destination networks
    /// @dev Process: 1) Detect source adapters, 2) For each destination network: register compatible adapters, 3) Wire them
    function run() public {
        string memory localNetwork = vm.envString("NETWORK");
        string memory localConfig = fetchConfig(localNetwork);

        // Detect and store all source adapter addresses
        // This populates the global adapters array and sets source adapter addresses
        localWormholeAddr = _maybeAddLocalAdapter(localConfig, "WormholeAdapter", localNetwork);
        localLayerZeroAddr = _maybeAddLocalAdapter(localConfig, "LayerZeroAdapter", localNetwork);
        localAxelarAddr = _maybeAddLocalAdapter(localConfig, "AxelarAdapter", localNetwork);

        // Get list of destination networks to connect to
        string[] memory connectsTo = vm.parseJsonStringArray(localConfig, "$.network.connectsTo");
        IProtocolGuardian protocolGuardian = IProtocolGuardian(vm.parseJsonAddress(localConfig, "$.contracts.protocolGuardian"));

        vm.startBroadcast();

        // For each destination network, wire adapters
        for (uint256 i = 0; i < connectsTo.length; i++) {
            string memory remoteNetwork = connectsTo[i];
            string memory remoteConfig = fetchConfig(remoteNetwork);
            uint16 remoteCentrifugeId = uint16(vm.parseJsonUint(remoteConfig, "$.network.centrifugeId"));

            // Build adapter array
            // Only include adapters that exist on BOTH source and destination networks
            IAdapter[] memory remoteAdapters = new IAdapter[](3); // Max 3 adapters
            uint8 count = 0;

            // Wormhole (source → destination)
            if (localWormholeAddr != address(0)) {
                address remoteWormholeAddr = _maybeAddLocalAdapter(remoteConfig, "WormholeAdapter", remoteNetwork);
                if (remoteWormholeAddr != address(0)) {
                    remoteAdapters[count] = IAdapter(localWormholeAddr);
                    count++;
                    bytes memory wormholeData = abi.encode(
                        uint16(vm.parseJsonUint(remoteConfig, "$.adapters.wormhole.wormholeId")),
                        remoteWormholeAddr
                    );
                    protocolGuardian.wire(localWormholeAddr, remoteCentrifugeId, wormholeData);
                    console.log("Wired WormholeAdapter from source", localNetwork, "to destination", remoteNetwork);
                }
            }

            // LayerZero (source → destination)
            if (localLayerZeroAddr != address(0)) {
                address remoteLayerZeroAddr = _maybeAddLocalAdapter(remoteConfig, "LayerZeroAdapter", remoteNetwork);
                if (remoteLayerZeroAddr != address(0)) {
                    remoteAdapters[count] = IAdapter(localLayerZeroAddr);
                    count++;
                    bytes memory layerZeroData = abi.encode(
                        GAS_MULTIPLIER,
                        uint32(vm.parseJsonUint(remoteConfig, "$.adapters.layerZero.layerZeroEid")),
                        remoteLayerZeroAddr
                    );
                    protocolGuardian.wire(localLayerZeroAddr, remoteCentrifugeId, layerZeroData);
                    console.log("Wired LayerZeroAdapter from source", localNetwork, "to destination", remoteNetwork);
                }
            }

            // Axelar (source → destination)
            if (localAxelarAddr != address(0)) {
                address remoteAxelarAddr = _maybeAddLocalAdapter(remoteConfig, "AxelarAdapter", remoteNetwork);
                if (remoteAxelarAddr != address(0)) {
                    remoteAdapters[count] = IAdapter(localAxelarAddr);
                    count++;
                    bytes memory axelarData = abi.encode(
                        GAS_MULTIPLIER,
                        vm.parseJsonString(remoteConfig, "$.adapters.axelar.axelarId"),
                        vm.toString(remoteAxelarAddr)
                    );
                    protocolGuardian.wire(localAxelarAddr, remoteCentrifugeId, axelarData);
                    console.log("Wired AxelarAdapter from source", localNetwork, "to destination", remoteNetwork);
                }
            }
            // Final step: Register adapters configured in the source network
            // This tells MultiAdapter which SOURCE adapters to use when sending to this DESTINATION network
            IAdapter[] memory adaptersToRegister = new IAdapter[](count);
            // Note: remoteAdapters has fixed capacity (3). setAdapters expects an array sized exactly
            // to the number of active adapters (count). Rebuild to avoid passing unused slots.
            for (uint8 j = 0; j < count; j++) {
                adaptersToRegister[j] = remoteAdapters[j];
            }

            if (count == 0) {
                console.log("Skipping registration for", remoteNetwork, ": no compatible adapters");
            } else {
                uint8 threshold = uint8(count);
                uint8 recoveryIndex = uint8(count - 1);
                protocolGuardian.setAdapters(remoteCentrifugeId, adaptersToRegister, threshold, recoveryIndex);
                console.log("Registered", count, "source adapters on", vm.envString("NETWORK"));
                console.log("Registered adapters for destination", remoteNetwork);
            }            
        }
        vm.stopBroadcast();
    }
}
