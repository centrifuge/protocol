// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "../src/core/messaging/interfaces/IAdapter.sol";

import {IOpsGuardian} from "../src/admin/interfaces/IOpsGuardian.sol";
import {IProtocolGuardian} from "../src/admin/interfaces/IProtocolGuardian.sol";

import "forge-std/Script.sol";

/// @title WireAdapters
/// @notice Configures the local network's adapters to communicate with remote networks.
/// @dev This script sets up one-directional communication (local → remote).
///      For bidirectional communication, the script must be run on each network separately.
///      
///      The script enforces symmetric adapter configuration:
///      - Only registers adapters that exist on BOTH local and remote networks
///      - Only wires adapters that are configured for the remote network
///      - Prevents InvalidAdapter errors from asymmetric configurations
///
///      Intended for testnet use only.
contract WireAdapters is Script {
    IAdapter[] adapters; // Storage array for adapter instances (populated during local adapter detection)
    address private localWormholeAddr;  // Local Wormhole adapter address (if deployed)
    address private localLayerZeroAddr; // Local LayerZero adapter address (if deployed)
    address private localAxelarAddr;    // Local Axelar adapter address (if deployed)

    /// @notice Detects and stores local adapter addresses from local network config
    /// @dev Checks if adapter is deployed locally and adds it to the global adapters array
    /// @param localConfig JSON config of the local network
    /// @param jsonPath JSON path to the adapter address (e.g., "$.contracts.wormholeAdapter")
    /// @param adapterLabel Human-readable name for logging
    /// @param localNetwork Name of the local network for logging
    /// @return addr The adapter address if found, address(0) if not found
    function _maybeAddLocalAdapter(
        string memory localConfig,
        string memory jsonPath,
        string memory adapterLabel,
        string memory localNetwork
    ) private returns (address addr) {
        addr = address(0);
        try vm.parseJsonAddress(localConfig, jsonPath) returns (address parsed) {
            if (parsed != address(0)) {
                adapters.push(IAdapter(parsed)); // Add to global adapters array for later use
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


    /// @notice Wires the local Wormhole adapter to a remote network
    /// @dev Only wires if: 1) local adapter exists, 2) remote has deploy: true, 3) remote adapter exists
    /// @param remoteNetwork Name of the remote network (e.g., "base-sepolia")
    /// @param remoteConfig JSON config of the remote network
    /// @param protocolGuardian ProtocolGuardian contract for wiring operations (allows re-wiring)
    function _wireWormhole(
        string memory remoteNetwork,
        string memory remoteConfig,
        IProtocolGuardian protocolGuardian
    ) private {
        // Check if local Wormhole adapter exists
        if (localWormholeAddr == address(0)) {
            console.log("Skipping Wormhole: local adapter not present on", vm.envString("NETWORK"));
            return;
        }
        
        // Check if remote network has Wormhole enabled (deploy: true)
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
        
        // Get remote adapter address and Wormhole ID
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
        
        // Wire the local adapter to the remote network
        uint16 remoteCentrifugeId = uint16(vm.parseJsonUint(remoteConfig, "$.network.centrifugeId"));
        bytes memory data = abi.encode(remoteId, remoteAdapter);
        protocolGuardian.wire(localWormholeAddr, remoteCentrifugeId, data);
        console.log("Wired WormholeAdapter from", vm.envString("NETWORK"), "to", remoteNetwork);
    }

    /// @notice Wires the local LayerZero adapter to a remote network
    /// @dev Only wires if: 1) local adapter exists, 2) remote has deploy: true, 3) remote adapter exists
    /// @param remoteNetwork Name of the remote network (e.g., "base-sepolia")
    /// @param remoteConfig JSON config of the remote network
    /// @param protocolGuardian ProtocolGuardian contract for wiring operations (allows re-wiring)
    function _wireLayerZero(
        string memory remoteNetwork,
        string memory remoteConfig,
        IProtocolGuardian protocolGuardian
    ) private {
        // Check if local LayerZero adapter exists
        if (localLayerZeroAddr == address(0)) {
            console.log("Skipping LayerZero: local adapter not present on", vm.envString("NETWORK"));
            return;
        }
        
        // Check if remote network has LayerZero enabled (deploy: true)
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
        
        // Get remote adapter address and LayerZero EID
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
        
        // Wire the local adapter to the remote network
        uint16 remoteCentrifugeId = uint16(vm.parseJsonUint(remoteConfig, "$.network.centrifugeId"));
        bytes memory data = abi.encode(remoteEid, remoteAdapter);
        protocolGuardian.wire(localLayerZeroAddr, remoteCentrifugeId, data);
        console.log("Wired LayerZeroAdapter from", vm.envString("NETWORK"), "to", remoteNetwork);
    }

    /// @notice Wires the local Axelar adapter to a remote network
    /// @dev Only wires if: 1) local adapter exists, 2) remote has deploy: true, 3) remote adapter exists
    /// @param remoteNetwork Name of the remote network (e.g., "base-sepolia")
    /// @param remoteConfig JSON config of the remote network
    /// @param protocolGuardian ProtocolGuardian contract for wiring operations (allows re-wiring)
    function _wireAxelar(
        string memory remoteNetwork,
        string memory remoteConfig,
        IProtocolGuardian protocolGuardian
    ) private {
        // Check if local Axelar adapter exists
        if (localAxelarAddr == address(0)) {
            console.log("Skipping Axelar: local adapter not present on", vm.envString("NETWORK"));
            return;
        }
        
        // Check if remote network has Axelar enabled (deploy: true)
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
        
        // Get remote adapter address and Axelar ID
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
        
        // Wire the local adapter to the remote network
        uint16 remoteCentrifugeId = uint16(vm.parseJsonUint(remoteConfig, "$.network.centrifugeId"));
        bytes memory data = abi.encode(remoteAxelarId, vm.toString(remoteAdapter));
        protocolGuardian.wire(localAxelarAddr, remoteCentrifugeId, data);
        console.log("Wired AxelarAdapter from", vm.envString("NETWORK"), "to", remoteNetwork);
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

    /// @notice Main function that configures adapters for all remote networks
    /// @dev Process: 1) Detect local adapters, 2) For each remote network: register compatible adapters, 3) Wire them
    function run() public {
        string memory localNetwork = vm.envString("NETWORK");
        string memory localConfig = fetchConfig(localNetwork);

        // STEP 1: Detect and store all local adapter addresses
        // This populates the global adapters array and sets local adapter addresses
        localWormholeAddr = _maybeAddLocalAdapter(localConfig, "$.contracts.wormholeAdapter", "WormholeAdapter", localNetwork);
        localLayerZeroAddr = _maybeAddLocalAdapter(localConfig, "$.contracts.layerZeroAdapter", "LayerZeroAdapter", localNetwork);
        localAxelarAddr = _maybeAddLocalAdapter(localConfig, "$.contracts.axelarAdapter", "AxelarAdapter", localNetwork);

        // Get list of remote networks to connect to from local config
        string[] memory connectsTo = vm.parseJsonStringArray(localConfig, "$.network.connectsTo");
        IOpsGuardian opsGuardian = IOpsGuardian(vm.parseJsonAddress(localConfig, "$.contracts.opsGuardian"));
        IProtocolGuardian protocolGuardian = IProtocolGuardian(vm.parseJsonAddress(localConfig, "$.contracts.protocolGuardian"));

        vm.startBroadcast();
        
        // STEP 2: For each remote network, configure adapters
        for (uint256 i = 0; i < connectsTo.length; i++) {
            string memory remoteNetwork = connectsTo[i];
            string memory remoteConfig = fetchConfig(remoteNetwork);
            uint16 remoteCentrifugeId = uint16(vm.parseJsonUint(remoteConfig, "$.network.centrifugeId"));

            // STEP 2A: Build adapter array for THIS remote network only
            // Only include adapters that exist on BOTH local and remote networks
            IAdapter[] memory remoteAdapters = new IAdapter[](3); // Max 3 adapters
            uint8 count = 0;

            // Check Wormhole: only add if BOTH chains have it deployed and configured
            if (localWormholeAddr != address(0)) {
                bool wormholeDeploy = false;
                address remoteWormholeAddr = address(0);
                try vm.parseJsonBool(remoteConfig, "$.adapters.wormhole.deploy") returns (bool value) {
                    wormholeDeploy = value;
                } catch {}
                try vm.parseJsonAddress(remoteConfig, "$.contracts.wormholeAdapter") returns (address addr) {
                    remoteWormholeAddr = addr;
                } catch {}
                if (wormholeDeploy && remoteWormholeAddr != address(0)) {
                    remoteAdapters[count] = IAdapter(localWormholeAddr);
                    count++;
                } else if (wormholeDeploy || remoteWormholeAddr != address(0)) {
                    if (wormholeDeploy && remoteWormholeAddr == address(0)) {
                        console.log("WARNING: Wormhole configured for", remoteNetwork, "but adapter not deployed there - skipping");
                    } else if (!wormholeDeploy && remoteWormholeAddr != address(0)) {
                        console.log("WARNING: Wormhole deployed on", remoteNetwork, "but not configured for", vm.envString("NETWORK"));
                        console.log("Skipping Wormhole for", remoteNetwork);
                    }
                }
            }

            // Check LayerZero: only add if BOTH chains have it deployed and configured
            if (localLayerZeroAddr != address(0)) {
                bool layerZeroDeploy = false;
                address remoteLayerZeroAddr = address(0);
                try vm.parseJsonBool(remoteConfig, "$.adapters.layerZero.deploy") returns (bool value) {
                    layerZeroDeploy = value;
                } catch {}
                try vm.parseJsonAddress(remoteConfig, "$.contracts.layerZeroAdapter") returns (address addr) {
                    remoteLayerZeroAddr = addr;
                } catch {}
                if (layerZeroDeploy && remoteLayerZeroAddr != address(0)) {
                    remoteAdapters[count] = IAdapter(localLayerZeroAddr);
                    count++;
                } else if (layerZeroDeploy || remoteLayerZeroAddr != address(0)) {
                    if (layerZeroDeploy && remoteLayerZeroAddr == address(0)) {
                        console.log("WARNING: LayerZero configured for", remoteNetwork, "but adapter not deployed there - skipping");
                    } else if (!layerZeroDeploy && remoteLayerZeroAddr != address(0)) {
                        console.log("WARNING: LayerZero deployed on", remoteNetwork, "but not configured for", vm.envString("NETWORK"));
                        console.log("Skipping LayerZero for", remoteNetwork);
                    }
                }
            }

            // Check Axelar: only add if BOTH chains have it deployed and configured
            if (localAxelarAddr != address(0)) {
                bool axelarDeploy = false;
                address remoteAxelarAddr = address(0);
                try vm.parseJsonBool(remoteConfig, "$.adapters.axelar.deploy") returns (bool value) {
                    axelarDeploy = value;
                } catch {}
                try vm.parseJsonAddress(remoteConfig, "$.contracts.axelarAdapter") returns (address addr) {
                    remoteAxelarAddr = addr;
                } catch {}
                if (axelarDeploy && remoteAxelarAddr != address(0)) {
                    remoteAdapters[count] = IAdapter(localAxelarAddr);
                    count++;
                } else if (axelarDeploy || remoteAxelarAddr != address(0)) {
                    if (axelarDeploy && remoteAxelarAddr == address(0)) {
                        console.log("WARNING: Axelar configured for", remoteNetwork, "but adapter not deployed there - skipping");
                    } else if (!axelarDeploy && remoteAxelarAddr != address(0)) {
                        console.log("WARNING: Axelar deployed on", remoteNetwork, "but not configured for", vm.envString("NETWORK"));
                        console.log("Skipping Axelar for", remoteNetwork);
                    }
                }
            }

            // STEP 2B: Register adapters for THIS remote network in MultiAdapter
            // This tells MultiAdapter which adapters to use when sending to this remote network
            IAdapter[] memory adaptersToRegister = new IAdapter[](count);
            for (uint8 j = 0; j < count; j++) {
                adaptersToRegister[j] = remoteAdapters[j];
            }

            if (count == 0) {
                console.log("Skipping registration for", remoteNetwork, ": no compatible adapters");
            } else {
                uint8 threshold = uint8(count);
                uint8 recoveryIndex = uint8(count - 1);
                protocolGuardian.setAdapters(remoteCentrifugeId, adaptersToRegister, threshold, recoveryIndex);
                console.log("Registered", count, "adapters from", vm.envString("NETWORK"));
                console.log("Registered adapters for", remoteNetwork);
            }

            // STEP 2C: Wire each adapter to THIS remote network
            // This configures each adapter with the remote network's specific settings
            _wireWormhole(remoteNetwork, remoteConfig, protocolGuardian);
            _wireLayerZero(remoteNetwork, remoteConfig, protocolGuardian);
            _wireAxelar(remoteNetwork, remoteConfig, protocolGuardian);
        }
        vm.stopBroadcast();
    }
}
