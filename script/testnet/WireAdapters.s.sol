// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "../../src/core/messaging/interfaces/IAdapter.sol";
import {IOpsGuardian} from "../../src/admin/interfaces/IOpsGuardian.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {Env, EnvConfig, Connection} from "../utils/EnvConfig.s.sol";

/// @title WireAdapters
/// @notice Configures the source network's global adapters to communicate with destination networks.
/// @dev This script sets up one-directional communication (source -> destination).
///      For bidirectional communication, the script must be run on each network separately.
///
///      The script enforces symmetric adapter configuration:
///      - Only registers adapters that exist on BOTH source and destination networks
///      - Only wires adapters that are configured for the destination network
///      - Prevents InvalidAdapter errors from asymmetric configurations
///
///      Intended for testnet use only.
contract WireAdapters is Script {
    IAdapter[] adapters;

    function run() public {
        EnvConfig memory source = Env.load(vm.envString("NETWORK"));

        require(!source.network.isMainnet(), "Script only for testnet");

        IOpsGuardian opsGuardian = IOpsGuardian(source.contracts.opsGuardian);
        Connection[] memory connections = source.network.connections();

        vm.startBroadcast();

        for (uint256 i = 0; i < connections.length; i++) {
            Connection memory connection = connections[i];
            EnvConfig memory remote = Env.load(connection.network);

            if (connection.wormhole) {
                adapters.push(IAdapter(source.contracts.wormholeAdapter));
                opsGuardian.wire(
                    source.contracts.wormholeAdapter,
                    remote.network.centrifugeId,
                    abi.encode(remote.adapters.wormhole.wormholeId, remote.contracts.wormholeAdapter)
                );
                console.log("Wired Wormhole from source", source.network.name, "to destination", connection.network);
            }

            if (connection.layerZero) {
                adapters.push(IAdapter(source.contracts.layerZeroAdapter));
                opsGuardian.wire(
                    source.contracts.layerZeroAdapter,
                    remote.network.centrifugeId,
                    abi.encode(remote.adapters.layerZero.layerZeroEid, remote.contracts.layerZeroAdapter)
                );
                console.log("Wired LayerZero from source", source.network.name, "to destination", connection.network);
            }

            if (connection.axelar) {
                adapters.push(IAdapter(source.contracts.axelarAdapter));
                opsGuardian.wire(
                    source.contracts.axelarAdapter,
                    remote.network.centrifugeId,
                    abi.encode(remote.adapters.axelar.axelarId, vm.toString(remote.contracts.axelarAdapter))
                );
                console.log("Wired Axelar from source", source.network.name, "to destination", connection.network);
            }

            if (connection.chainlink) {
                adapters.push(IAdapter(source.contracts.chainlinkAdapter));
                opsGuardian.wire(
                    source.contracts.chainlinkAdapter,
                    remote.network.centrifugeId,
                    abi.encode(remote.adapters.chainlink.chainSelector, remote.contracts.chainlinkAdapter)
                );
                console.log("Wired Chainlink from source", source.network.name, "to destination", connection.network);
            }

            if (adapters.length == 0) {
                console.log("Skipping registration for", connection.network, ": no compatible adapters");
                continue;
            }

            opsGuardian.initAdapters(
                remote.network.centrifugeId, adapters, connection.threshold, uint8(adapters.length)
            );
            console.log("Registered", adapters.length, "source adapters for destination", connection.network);
        }

        vm.stopBroadcast();
    }
}
