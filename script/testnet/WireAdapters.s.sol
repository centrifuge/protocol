// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "../../src/core/messaging/interfaces/IAdapter.sol";
import {IOpsGuardian} from "../../src/admin/interfaces/IOpsGuardian.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {Env, EnvConfig, Connection} from "../utils/EnvConfig.s.sol";

/// @title WireAdapters
/// @notice Configures the source network's adapters to communicate with destination networks.
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
    /// @notice Main function that configures adapters for all destination networks
    function run() public {
        string memory sourceNetwork = vm.envString("NETWORK");
        EnvConfig memory source = Env.load(sourceNetwork);

        require(
            keccak256(bytes(source.network.environment)) == keccak256("testnet"),
            "This script is intended for testnet use only"
        );

        IOpsGuardian opsGuardian = IOpsGuardian(source.contracts.opsGuardian);

        vm.startBroadcast();

        for (uint256 i = 0; i < source.network.connections.length; i++) {
            Connection memory conn = source.network.connections[i];
            EnvConfig memory remote = Env.load(conn.network);

            IAdapter[] memory adapters = new IAdapter[](3);
            uint8 count = 0;

            // Wormhole (source -> destination)
            if (
                conn.wormhole && source.contracts.wormholeAdapter != address(0)
                    && remote.contracts.wormholeAdapter != address(0)
            ) {
                adapters[count++] = IAdapter(source.contracts.wormholeAdapter);
                opsGuardian.wire(
                    source.contracts.wormholeAdapter,
                    remote.network.centrifugeId,
                    abi.encode(remote.adapters.wormhole.wormholeId, remote.contracts.wormholeAdapter)
                );
                console.log("Wired WormholeAdapter from source", sourceNetwork, "to destination", conn.network);
            }

            // LayerZero (source -> destination)
            if (
                conn.layerZero && source.contracts.layerZeroAdapter != address(0)
                    && remote.contracts.layerZeroAdapter != address(0)
            ) {
                adapters[count++] = IAdapter(source.contracts.layerZeroAdapter);
                opsGuardian.wire(
                    source.contracts.layerZeroAdapter,
                    remote.network.centrifugeId,
                    abi.encode(remote.adapters.layerZero.layerZeroEid, remote.contracts.layerZeroAdapter)
                );
                console.log("Wired LayerZeroAdapter from source", sourceNetwork, "to destination", conn.network);
            }

            // Axelar (source -> destination)
            if (
                conn.axelar && source.contracts.axelarAdapter != address(0)
                    && remote.contracts.axelarAdapter != address(0)
            ) {
                adapters[count++] = IAdapter(source.contracts.axelarAdapter);
                opsGuardian.wire(
                    source.contracts.axelarAdapter,
                    remote.network.centrifugeId,
                    abi.encode(remote.adapters.axelar.axelarId, vm.toString(remote.contracts.axelarAdapter))
                );
                console.log("Wired AxelarAdapter from source", sourceNetwork, "to destination", conn.network);
            }

            if (count == 0) {
                console.log("Skipping registration for", conn.network, ": no compatible adapters");
                continue;
            }

            // Rebuild array to exact size for initAdapters
            IAdapter[] memory adaptersToRegister = new IAdapter[](count);
            for (uint8 j = 0; j < count; j++) {
                adaptersToRegister[j] = adapters[j];
            }

            uint8 recoveryIndex = uint8(count - 1);
            opsGuardian.initAdapters(remote.network.centrifugeId, adaptersToRegister, conn.threshold, recoveryIndex);
            console.log("Registered", count, "source adapters for destination", conn.network);
        }

        vm.stopBroadcast();
    }
}
