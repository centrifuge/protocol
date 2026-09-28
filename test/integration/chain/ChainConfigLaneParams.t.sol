// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Connection} from "../../../script/utils/ConnectionsConfig.s.sol";
import {Chains, ChainConfig, ChainConfigLib} from "../../../script/utils/ChainConfig.s.sol";

import "forge-std/Test.sol";

import {SetConfigParam} from "../../../src/deployment/interfaces/ILayerZeroEndpointV2Like.sol";

/// @title  ChainConfigLaneParamsTest
/// @notice What `buildLayerZeroConfigParams` hands the adapter batcher, built from the anvil fixtures: the
///         only configs this branch carries. They name no DVN override, so this pins the default path and the
///         shape of the array; the override lookup itself is asserted in `ChainConfigDvnParsing.t.sol`.
contract ChainConfigLaneParamsTest is Test {
    /// @dev The batcher reads the params by connection index, so the array has one slot per connection, in
    ///      `connections()` order — the order `adapterConnections()` builds its own array in
    function test_oneParamPerConnectionInConnectionOrder() public view {
        ChainConfig memory config = Chains.load("local-a", Chains.FIXTURE_ENVIRONMENT);
        Connection[] memory connections = config.network.connections();
        SetConfigParam[] memory params = config.buildLayerZeroConfigParams();

        assertGt(connections.length, 0, "the fixtures connect the local pair");
        assertEq(params.length, connections.length, "one param per connection");

        for (uint256 i; i < connections.length; i++) {
            assertTrue(connections[i].layerZero, "the fixtures connect over LayerZero");
            ChainConfig memory remote = Chains.load(connections[i].network, Chains.FIXTURE_ENVIRONMENT);

            assertEq(params[i].eid, remote.adapters.layerZero.layerZeroEid, "the slot names its own peer");
            assertEq(params[i].configType, ChainConfigLib.ULN_CONFIG_TYPE);
            assertEq(
                params[i].config,
                ChainConfigLib.encodeUlnConfig(config.adapters.layerZero),
                "a lane with no override uses the default set"
            );
        }
    }
}
