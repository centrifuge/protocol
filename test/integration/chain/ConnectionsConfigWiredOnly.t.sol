// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ChainConfig, ChainConfigLib} from "../../../script/utils/ChainConfig.s.sol";
import {EnvConnections, ConnectionsConfig, Connection} from "../../../script/utils/ConnectionsConfig.s.sol";

import "forge-std/Test.sol";

import {AdapterConnections} from "../../../src/deployment/ActionBatchers.sol";

/// @title  ConnectionsConfigWiredOnlyTest
/// @notice How a connection rule's `wiredOnly` list resolves: adapters wired to the lane but kept out of its
///         global adapter set. Hermetic, on JSON written here, like the DVN parsing tests.
contract ConnectionsConfigWiredOnlyTest is Test {
    function _json(string memory rules) private pure returns (string memory) {
        return string.concat('{"aliases":{"ALL":["a","b","c"]},"connections":[', rules, "]}");
    }

    function _only(Connection[] memory connections, string memory network) private pure returns (Connection memory) {
        for (uint256 i; i < connections.length; i++) {
            if (keccak256(bytes(connections[i].network)) == keccak256(bytes(network))) return connections[i];
        }
        revert("no connection");
    }

    function test_wiredOnlyAdaptersStayOutOfTheSet() public view {
        ConnectionsConfig memory config = this.parse(
            _json('{"chains":["ALL","ALL"],"adapters":["layerZero","hyperlane"],"wiredOnly":["axelar"],"threshold":1}')
        );
        Connection memory c = _only(config.connectionsWith("a"), "b");

        assertTrue(c.layerZero && c.hyperlane, "in the set");
        assertFalse(c.axelar, "axelar is not in the set");
        assertTrue(c.axelarWiredOnly, "axelar is wired only");
        assertFalse(c.layerZeroWiredOnly || c.hyperlaneWiredOnly || c.chainlinkWiredOnly, "nothing else wired only");
        assertEq(c.threshold, 1);
    }

    /// @dev Rules written before the field existed resolve exactly as they did
    function test_aRuleWithoutWiredOnlyWiresNothingExtra() public view {
        ConnectionsConfig memory config =
            this.parse(_json('{"chains":["ALL","ALL"],"adapters":["axelar","layerZero"],"threshold":2}'));
        Connection memory c = _only(config.connectionsWith("a"), "b");

        assertTrue(c.axelar && c.layerZero);
        assertFalse(c.layerZeroWiredOnly || c.axelarWiredOnly || c.chainlinkWiredOnly || c.hyperlaneWiredOnly);
    }

    /// @dev A pool's first `SetPoolAdapters` travels over the lane's global set, so a lane wiring adapters with
    ///      no global set could never have one taken up
    function test_rejectsWiredOnlyAdaptersWithoutAGlobalSet() public {
        vm.expectRevert(bytes("connections[0]: wired-only adapters need a global set to be taken up over"));
        this.parse(_json('{"chains":[["a"],["b"]],"adapters":[],"wiredOnly":["axelar"],"threshold":0}'));
    }

    /// @dev A rule names its two sides in either order, and the lane resolves the same from both ends
    function test_aLaneResolvesTheSameFromBothEnds() public view {
        ConnectionsConfig memory config =
            this.parse(_json('{"chains":[["a"],["b"]],"adapters":["layerZero"],"wiredOnly":["axelar"],"threshold":1}'));
        Connection memory fromA = _only(config.connectionsWith("a"), "b");
        Connection memory fromB = _only(config.connectionsWith("b"), "a");

        assertTrue(fromA.layerZero && fromB.layerZero, "set");
        assertTrue(fromA.axelarWiredOnly && fromB.axelarWiredOnly, "wired only");
        assertEq(fromA.threshold, fromB.threshold);
    }

    function test_rejectsAThresholdAboveTheSet() public {
        vm.expectRevert(bytes("connections[0]: threshold above the adapter set"));
        this.parse(_json('{"chains":["ALL","ALL"],"adapters":["layerZero"],"wiredOnly":["axelar"],"threshold":2}'));
    }

    /// @dev A rule naming no adapter disconnects its lanes, and asks no confirmations of them
    function test_rejectsAThresholdWithoutASet() public {
        vm.expectRevert(bytes("connections[0]: threshold without an adapter set"));
        this.parse(_json('{"chains":[["a"],["b"]],"adapters":[],"threshold":1}'));
    }

    /// @dev A misspelled key would drop its list unread, the way a misspelled adapter name would
    function test_rejectsAnUnknownKey() public {
        vm.expectRevert(bytes("connections[0]: unknown key wired_only"));
        this.parse(_json('{"chains":["ALL","ALL"],"adapters":["layerZero"],"wired_only":["axelar"],"threshold":1}'));
    }

    /// @dev The list is part of the rule, so the last matching rule decides it like it decides the set
    function test_theLastMatchingRuleDecidesWiredOnlyToo() public view {
        ConnectionsConfig memory config = this.parse(
            _json(
                string.concat(
                    '{"chains":["ALL","ALL"],"adapters":["layerZero"],"wiredOnly":["axelar"],"threshold":1},',
                    '{"chains":[["a"],["b"]],"adapters":["layerZero","axelar"],"threshold":2}'
                )
            )
        );

        Connection memory ab = _only(config.connectionsWith("a"), "b");
        assertTrue(ab.axelar, "the later rule puts axelar in the a-b set");
        assertFalse(ab.axelarWiredOnly);

        Connection memory ac = _only(config.connectionsWith("a"), "c");
        assertTrue(ac.axelarWiredOnly, "a-c keeps the first rule");
    }

    function test_rejectsAnAdapterInBothLists() public {
        vm.expectRevert(bytes("connections[0]: axelar is both in the adapter set and wired only"));
        this.parse(
            _json('{"chains":["ALL","ALL"],"adapters":["axelar","layerZero"],"wiredOnly":["axelar"],"threshold":1}')
        );
    }

    function test_rejectsAnUnknownWiredOnlyAdapter() public {
        vm.expectRevert(bytes("connections[0]: unknown adapter Axelar"));
        this.parse(_json('{"chains":["ALL","ALL"],"adapters":["layerZero"],"wiredOnly":["Axelar"],"threshold":1}'));
    }

    /// @dev A misspelled set adapter used to be dropped without a word, the lane going unwired for it
    function test_rejectsAnUnknownSetAdapter() public {
        vm.expectRevert(bytes("connections[0]: unknown adapter layerzero"));
        this.parse(_json('{"chains":["ALL","ALL"],"adapters":["layerzero"],"threshold":1}'));
    }

    /// @dev What the batcher is handed: an adapter the lane names in either list gets its id, which is what the
    ///      batcher wires on, and only the flag says whether it also joins the set
    function test_aWiredOnlyAdapterGetsItsIdSoTheBatcherWiresIt() public pure {
        ChainConfig memory remote;
        remote.network.centrifugeId = 7;
        remote.adapters.layerZero.layerZeroEid = 40_007;
        remote.adapters.axelar.axelarId = "remote-7";
        remote.adapters.chainlink.chainSelector = 7007;
        remote.adapters.hyperlane.hyperlaneId = 7;

        Connection memory connection;
        connection.layerZero = true; // in the set
        connection.axelarWiredOnly = true; // wired only
        connection.threshold = 1; // hyperlane and chainlink: not named at all

        AdapterConnections memory lane = ChainConfigLib.adapterConnection(connection, remote);

        assertEq(lane.centrifugeId, 7);
        assertEq(lane.layerZeroId, 40_007, "in the set: wired");
        assertFalse(lane.layerZeroWiredOnly);
        assertEq(lane.axelarId, "remote-7", "wired only: still wired");
        assertTrue(lane.axelarWiredOnly, "and kept out of the set");
        assertEq(lane.chainlinkId, 0, "not named: not wired");
        assertEq(lane.hyperlaneId, 0, "not named: not wired");
        assertEq(lane.threshold, 1);
    }

    /// @dev An adapter one end does not deploy would get no id, or no adapter to wire with, and be skipped
    ///      without a word; a wired-only one would not be noticed until a pool reached for it
    function test_rejectsALaneWiringAnAdapterAnEndDoesNotDeploy() public {
        ChainConfig memory local;
        local.network.name = "a";
        local.adapters.layerZero.deploy = true;
        local.adapters.axelar.deploy = true;
        ChainConfig memory remote;
        remote.network.name = "b";
        remote.adapters.layerZero.deploy = true; // no axelar here

        Connection memory connection;
        connection.layerZero = true;
        this.requireLaneDeployed(connection, local, remote); // fine: both ends deploy LayerZero

        connection.axelarWiredOnly = true;
        vm.expectRevert(bytes("a <-> b: axelar is not deployed on b"));
        this.requireLaneDeployed(connection, local, remote);
    }

    function requireLaneDeployed(Connection memory connection, ChainConfig memory local, ChainConfig memory remote)
        external
        pure
    {
        ChainConfigLib.requireLaneDeployed(connection, local, remote);
    }

    /// @dev An external hop, so that `vm.expectRevert` sees the revert at a lower depth than its own call
    function parse(string memory json) external view returns (ConnectionsConfig memory) {
        return EnvConnections.parse(json);
    }
}
