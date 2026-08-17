// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {Env, EnvConfig} from "../utils/EnvConfig.s.sol";
import {Connection} from "../utils/EnvConnectionsConfig.s.sol";

/// @notice Prints the networks a hub is connected to, one per line, so a shell script can loop over them
///         without reimplementing the rules in `env/connections/<environment>.json`.
///
/// @dev    forge script script/testnet/Connections.s.sol --sig 'spokesOf(string)' base-sepolia
///
///         Resolving a connection means resolving aliases and literal arrays, letting the last matching rule
///         win, and dropping a pair whose winning rule has no adapters left. That belongs in exactly one
///         place — `EnvConnections.connectionsWith`, which the deploy and wiring scripts already use — so
///         this only formats what it answers. Reads env/ and touches no chain, so it needs no --rpc-url.
contract Connections is Script {
    function spokesOf(string memory hub) public view {
        EnvConfig memory config = Env.load(hub);
        Connection[] memory connections = config.network.connections();

        for (uint256 i; i < connections.length; i++) {
            console.log(connections[i].network);
        }
    }
}
