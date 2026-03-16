// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {MultiAdapter} from "../../../../src/core/messaging/MultiAdapter.sol";
import {IAdapter} from "../../../../src/core/messaging/interfaces/IAdapter.sol";

import {Connection} from "../../../../script/utils/EnvConnectionsConfig.s.sol";
import {Env, EnvConfig, AdaptersConfig, ContractsConfig as C} from "../../../../script/utils/EnvConfig.s.sol";

import {AxelarAdapter} from "../../../../src/adapters/AxelarAdapter.sol";
import {WormholeAdapter} from "../../../../src/adapters/WormholeAdapter.sol";
import {ChainlinkAdapter} from "../../../../src/adapters/ChainlinkAdapter.sol";
import {LayerZeroAdapter} from "../../../../src/adapters/LayerZeroAdapter.sol";
import {BaseValidator, ValidationContext} from "../../spell/utils/validation/BaseValidator.sol";

/// @title Validate_AdapterConfigurations
/// @notice Validates MultiAdapter quorum/threshold/adapter order and adapter source/destination
///         mappings using connection topology from env/connections/*.json.
contract Validate_AdapterConfigurations is BaseValidator("AdapterConfigurations") {
    PoolId constant GLOBAL_POOL = PoolId.wrap(0);

    function validate(ValidationContext memory ctx) public override {
        C memory c = ctx.contracts.live;

        // Skip if no adapters deployed at all
        if (
            c.wormholeAdapter == address(0) && c.axelarAdapter == address(0) && c.layerZeroAdapter == address(0)
                && c.chainlinkAdapter == address(0)
        ) return;

        EnvConfig memory localConfig = Env.load(ctx.networkName);
        Connection[] memory connections = localConfig.network.connections();

        if (connections.length == 0) return;

        for (uint256 i; i < connections.length; i++) {
            _validateConnection(c, connections[i]);
        }
    }

    function _validateConnection(C memory c, Connection memory conn) internal {
        EnvConfig memory remoteConfig = Env.load(conn.network);
        uint16 remoteCentrifugeId = remoteConfig.network.centrifugeId;

        // Skip if not yet wired
        uint8 quorum = MultiAdapter(c.multiAdapter).quorum(remoteCentrifugeId, GLOBAL_POOL);
        if (quorum == 0) return;

        _validateQuorumAndThreshold(c.multiAdapter, remoteCentrifugeId, quorum, conn);
        _validateAdapterPresence(c, remoteCentrifugeId, quorum, conn);
        _validateMappings(c, remoteCentrifugeId, remoteConfig.adapters, conn);
    }

    function _validateQuorumAndThreshold(
        address multiAdapterAddr,
        uint16 remoteCentrifugeId,
        uint8 quorum,
        Connection memory conn
    ) internal {
        uint8 expectedQuorum = 0;
        if (conn.wormhole) expectedQuorum++;
        if (conn.axelar) expectedQuorum++;
        if (conn.layerZero) expectedQuorum++;
        if (conn.chainlink) expectedQuorum++;

        if (quorum != expectedQuorum) {
            _errors.push(
                _buildError(
                    "quorum",
                    conn.network,
                    vm.toString(expectedQuorum),
                    vm.toString(quorum),
                    string.concat("MultiAdapter quorum mismatch for ", conn.network)
                )
            );
        }

        MultiAdapter ma = MultiAdapter(multiAdapterAddr);

        uint8 threshold = ma.threshold(remoteCentrifugeId, GLOBAL_POOL);
        if (conn.threshold != 0 && threshold != conn.threshold) {
            _errors.push(
                _buildError(
                    "threshold",
                    conn.network,
                    vm.toString(conn.threshold),
                    vm.toString(threshold),
                    string.concat("MultiAdapter threshold mismatch for ", conn.network)
                )
            );
        }
        if (threshold > quorum) {
            _errors.push(
                _buildError(
                    "threshold",
                    conn.network,
                    string.concat("<= ", vm.toString(quorum)),
                    vm.toString(threshold),
                    string.concat("MultiAdapter threshold > quorum for ", conn.network)
                )
            );
        }

        uint8 recoveryIndex = ma.recoveryIndex(remoteCentrifugeId, GLOBAL_POOL);
        if (recoveryIndex > quorum) {
            _errors.push(
                _buildError(
                    "recoveryIndex",
                    conn.network,
                    string.concat("<= ", vm.toString(quorum)),
                    vm.toString(recoveryIndex),
                    string.concat("MultiAdapter recoveryIndex > quorum for ", conn.network)
                )
            );
        }
    }

    /// @dev Validates that all expected adapters are present in the MultiAdapter for this connection.
    ///      Does NOT validate ordering — adapter registration order is a deployment detail, not a protocol invariant.
    function _validateAdapterPresence(C memory c, uint16 remoteCentrifugeId, uint8 quorum, Connection memory conn)
        internal
    {
        MultiAdapter multiAdapter = MultiAdapter(c.multiAdapter);

        address[] memory onChainAdapters = new address[](quorum);
        for (uint8 i; i < quorum; i++) {
            try multiAdapter.adapters(remoteCentrifugeId, GLOBAL_POOL, i) returns (IAdapter adapter) {
                onChainAdapters[i] = address(adapter);
            } catch {
                break;
            }
        }

        if (conn.wormhole && c.wormholeAdapter != address(0)) {
            _checkAdapterPresent(onChainAdapters, c.wormholeAdapter, conn.network, "Wormhole");
        }
        if (conn.axelar && c.axelarAdapter != address(0)) {
            _checkAdapterPresent(onChainAdapters, c.axelarAdapter, conn.network, "Axelar");
        }
        if (conn.layerZero && c.layerZeroAdapter != address(0)) {
            _checkAdapterPresent(onChainAdapters, c.layerZeroAdapter, conn.network, "LayerZero");
        }
        if (conn.chainlink && c.chainlinkAdapter != address(0)) {
            _checkAdapterPresent(onChainAdapters, c.chainlinkAdapter, conn.network, "Chainlink");
        }
    }

    /// @dev Source/destination mappings use the local adapter address as expected remote address.
    ///      This is correct because CREATE3 guarantees identical adapter addresses across all chains.
    function _validateMappings(
        C memory c,
        uint16 remoteCentrifugeId,
        AdaptersConfig memory remoteAdapters,
        Connection memory conn
    ) internal {
        if (conn.wormhole && c.wormholeAdapter != address(0)) {
            _validateWormholeMapping(
                WormholeAdapter(c.wormholeAdapter),
                remoteAdapters.wormhole.wormholeId,
                remoteCentrifugeId,
                c.wormholeAdapter,
                conn.network
            );
        }
        if (conn.axelar && c.axelarAdapter != address(0)) {
            _validateAxelarMapping(
                AxelarAdapter(c.axelarAdapter),
                remoteAdapters.axelar.axelarId,
                remoteCentrifugeId,
                c.axelarAdapter,
                conn.network
            );
        }
        if (conn.layerZero && c.layerZeroAdapter != address(0)) {
            _validateLayerZeroMapping(
                LayerZeroAdapter(c.layerZeroAdapter),
                remoteAdapters.layerZero.layerZeroEid,
                remoteCentrifugeId,
                c.layerZeroAdapter,
                conn.network
            );
        }
        if (conn.chainlink && c.chainlinkAdapter != address(0)) {
            _validateChainlinkMapping(
                ChainlinkAdapter(c.chainlinkAdapter),
                remoteAdapters.chainlink.chainSelector,
                remoteCentrifugeId,
                c.chainlinkAdapter,
                conn.network
            );
        }
    }

    // ==================== HELPERS ====================

    function _checkAdapterPresent(
        address[] memory onChainAdapters,
        address expected,
        string memory chainName,
        string memory adapterName
    ) internal {
        for (uint256 i; i < onChainAdapters.length; i++) {
            if (onChainAdapters[i] == expected) return;
        }
        _errors.push(
            _buildError(
                "adapter",
                chainName,
                vm.toString(expected),
                "not found",
                string.concat(adapterName, " adapter not found in MultiAdapter for ", chainName)
            )
        );
    }

    function _validateWormholeMapping(
        WormholeAdapter adapter,
        uint16 wormholeId,
        uint16 centrifugeId,
        address expectedAddr,
        string memory chainName
    ) internal {
        (uint16 srcCentrifugeId, address srcAddr) = adapter.sources(wormholeId);
        if (srcCentrifugeId != centrifugeId) {
            _errors.push(
                _buildError(
                    "wormhole.source.centrifugeId",
                    chainName,
                    vm.toString(centrifugeId),
                    vm.toString(srcCentrifugeId),
                    string.concat("Wormhole source centrifugeId mismatch for ", chainName)
                )
            );
        }
        if (srcAddr != expectedAddr) {
            _errors.push(
                _buildError(
                    "wormhole.source.addr",
                    chainName,
                    vm.toString(expectedAddr),
                    vm.toString(srcAddr),
                    string.concat("Wormhole source address mismatch for ", chainName)
                )
            );
        }

        (uint16 destWormholeId, address destAddr) = adapter.destinations(centrifugeId);
        if (destWormholeId != wormholeId) {
            _errors.push(
                _buildError(
                    "wormhole.dest.wormholeId",
                    chainName,
                    vm.toString(wormholeId),
                    vm.toString(destWormholeId),
                    string.concat("Wormhole destination wormholeId mismatch for ", chainName)
                )
            );
        }
        if (destAddr != expectedAddr) {
            _errors.push(
                _buildError(
                    "wormhole.dest.addr",
                    chainName,
                    vm.toString(expectedAddr),
                    vm.toString(destAddr),
                    string.concat("Wormhole destination address mismatch for ", chainName)
                )
            );
        }
    }

    function _validateAxelarMapping(
        AxelarAdapter adapter,
        string memory axelarId,
        uint16 centrifugeId,
        address expectedAddr,
        string memory chainName
    ) internal {
        (uint16 srcCentrifugeId, bytes32 srcAddrHash) = adapter.sources(axelarId);
        if (srcCentrifugeId != centrifugeId) {
            _errors.push(
                _buildError(
                    "axelar.source.centrifugeId",
                    chainName,
                    vm.toString(centrifugeId),
                    vm.toString(srcCentrifugeId),
                    string.concat("Axelar source centrifugeId mismatch for ", chainName)
                )
            );
        }
        bytes32 expectedHash = keccak256(abi.encodePacked(vm.toString(expectedAddr)));
        if (srcAddrHash != expectedHash) {
            _errors.push(
                _buildError(
                    "axelar.source.addrHash",
                    chainName,
                    vm.toString(expectedHash),
                    vm.toString(srcAddrHash),
                    string.concat("Axelar source addressHash mismatch for ", chainName)
                )
            );
        }

        (string memory destAxelarId, string memory destAddr) = adapter.destinations(centrifugeId);
        if (keccak256(bytes(destAxelarId)) != keccak256(bytes(axelarId))) {
            _errors.push(
                _buildError(
                    "axelar.dest.axelarId",
                    chainName,
                    axelarId,
                    destAxelarId,
                    string.concat("Axelar destination axelarId mismatch for ", chainName)
                )
            );
        }
        if (keccak256(bytes(destAddr)) != keccak256(abi.encodePacked(vm.toString(expectedAddr)))) {
            _errors.push(
                _buildError(
                    "axelar.dest.addr",
                    chainName,
                    vm.toString(expectedAddr),
                    destAddr,
                    string.concat("Axelar destination address mismatch for ", chainName)
                )
            );
        }
    }

    function _validateLayerZeroMapping(
        LayerZeroAdapter adapter,
        uint32 layerZeroEid,
        uint16 centrifugeId,
        address expectedAddr,
        string memory chainName
    ) internal {
        (uint16 srcCentrifugeId, address srcAddr) = adapter.sources(layerZeroEid);
        if (srcCentrifugeId != centrifugeId) {
            _errors.push(
                _buildError(
                    "layerZero.source.centrifugeId",
                    chainName,
                    vm.toString(centrifugeId),
                    vm.toString(srcCentrifugeId),
                    string.concat("LayerZero source centrifugeId mismatch for ", chainName)
                )
            );
        }
        if (srcAddr != expectedAddr) {
            _errors.push(
                _buildError(
                    "layerZero.source.addr",
                    chainName,
                    vm.toString(expectedAddr),
                    vm.toString(srcAddr),
                    string.concat("LayerZero source address mismatch for ", chainName)
                )
            );
        }

        (uint32 destEid, address destAddr) = adapter.destinations(centrifugeId);
        if (destEid != layerZeroEid) {
            _errors.push(
                _buildError(
                    "layerZero.dest.eid",
                    chainName,
                    vm.toString(layerZeroEid),
                    vm.toString(destEid),
                    string.concat("LayerZero destination EID mismatch for ", chainName)
                )
            );
        }
        if (destAddr != expectedAddr) {
            _errors.push(
                _buildError(
                    "layerZero.dest.addr",
                    chainName,
                    vm.toString(expectedAddr),
                    vm.toString(destAddr),
                    string.concat("LayerZero destination address mismatch for ", chainName)
                )
            );
        }
    }

    function _validateChainlinkMapping(
        ChainlinkAdapter adapter,
        uint64 chainSelector,
        uint16 centrifugeId,
        address expectedAddr,
        string memory chainName
    ) internal {
        (uint16 srcCentrifugeId, address srcAddr) = adapter.sources(chainSelector);
        if (srcCentrifugeId != centrifugeId) {
            _errors.push(
                _buildError(
                    "chainlink.source.centrifugeId",
                    chainName,
                    vm.toString(centrifugeId),
                    vm.toString(srcCentrifugeId),
                    string.concat("Chainlink source centrifugeId mismatch for ", chainName)
                )
            );
        }
        if (srcAddr != expectedAddr) {
            _errors.push(
                _buildError(
                    "chainlink.source.addr",
                    chainName,
                    vm.toString(expectedAddr),
                    vm.toString(srcAddr),
                    string.concat("Chainlink source address mismatch for ", chainName)
                )
            );
        }

        (uint64 destSelector, address destAddr) = adapter.destinations(centrifugeId);
        if (destSelector != chainSelector) {
            _errors.push(
                _buildError(
                    "chainlink.dest.chainSelector",
                    chainName,
                    vm.toString(chainSelector),
                    vm.toString(destSelector),
                    string.concat("Chainlink destination chainSelector mismatch for ", chainName)
                )
            );
        }
        if (destAddr != expectedAddr) {
            _errors.push(
                _buildError(
                    "chainlink.dest.addr",
                    chainName,
                    vm.toString(expectedAddr),
                    vm.toString(destAddr),
                    string.concat("Chainlink destination address mismatch for ", chainName)
                )
            );
        }
    }
}
