// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Env, EnvConfig, Connection} from "./utils/EnvConfig.s.sol";

import {PoolId} from "../src/core/types/PoolId.sol";
import {IAdapter} from "../src/core/messaging/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../src/core/messaging/interfaces/IMultiAdapter.sol";

import {IOpsGuardian} from "../src/admin/interfaces/IOpsGuardian.sol";

import "forge-std/Script.sol";

import {Safe, Enum} from "safe-utils/Safe.sol";
import {LayerZeroAdapter} from "../src/adapters/LayerZeroAdapter.sol";
import {
    SetConfigParam,
    UlnConfig,
    ILayerZeroEndpointV2Like
} from "../src/deployment/interfaces/ILayerZeroEndpointV2Like.sol";

/// @title WireToNewNetwork
/// @notice Proposes batched OpsGuardian.wire/initAdapters and LZ DVN config transactions via Safe
///         to wire a source chain to one or more target chains.
/// @dev Run this script on each source chain that needs to be wired to target chain(s).
///      All ops Safe calls (wire + initAdapters) are batched into a single proposal.
///      All protocol Safe calls (LZ DVN config) are batched into a single proposal.
///      This minimizes signing rounds to at most 2 per source chain.
///
///      Set NETWORK env var to the source chain name (e.g., "ethereum", "base", "arbitrum").
///      Set TARGETS env var to comma-separated target chain names (e.g., "monad,pharos").
///
///      Example usage:
///        NETWORK=ethereum TARGETS=monad,pharos forge script script/WireToNewNetwork.s.sol --rpc-url $ETH_RPC_URL --broadcast
///        NETWORK=monad TARGETS=ethereum,base,arbitrum forge script script/WireToNewNetwork.s.sol --rpc-url $MONAD_RPC_URL --broadcast
contract WireToNewNetwork is Script {
    using Safe for *;

    string constant LEDGER_DERIVATION_PATH = "m/44'/60'/0'/0/0";
    uint32 constant ULN_CONFIG_TYPE = 2;

    Safe.Client safe;
    Safe.Client protocolSafe;

    function run() external {
        vm.startBroadcast();
        string memory networkName = vm.envString("NETWORK");
        string[] memory targetNames = vm.envString("TARGETS", ",");
        wireAll(networkName, targetNames, LEDGER_DERIVATION_PATH);
        configureLzDvnsAll(networkName, targetNames, LEDGER_DERIVATION_PATH);
        vm.stopBroadcast();
    }

    //----------------------------------------------------------------------------------------------
    // Multi-target batched entry points
    //----------------------------------------------------------------------------------------------

    /// @notice Wire adapters for multiple targets in a single batched ops Safe proposal.
    ///         Targets already wired (quorum > 0) are silently skipped.
    function wireAll(string memory networkName, string[] memory targetNames, string memory derivationPath) public {
        EnvConfig memory source = Env.load(networkName);
        (address[] memory targets, bytes[] memory datas) = _collectWireCalls(source, targetNames);
        if (targets.length == 0) return;
        _batchCall(safe, source.network.opsAdmin, targets, datas, derivationPath);
    }

    /// @notice Configure LZ DVNs for multiple targets in a single batched protocol Safe proposal.
    ///         Targets without a LayerZero connection are silently skipped.
    function configureLzDvnsAll(string memory networkName, string[] memory targetNames, string memory derivationPath)
        public
    {
        EnvConfig memory source = Env.load(networkName);
        (address[] memory targets, bytes[] memory datas) = _collectDvnCalls(source, targetNames);
        if (targets.length == 0) return;
        _batchCall(protocolSafe, source.network.protocolAdmin, targets, datas, derivationPath);
    }

    //----------------------------------------------------------------------------------------------
    // Single-target entry points (backward compat for tests)
    //----------------------------------------------------------------------------------------------

    function wire(string memory networkName, string memory targetName, string memory derivationPath) public {
        string[] memory targets = new string[](1);
        targets[0] = targetName;
        wireAll(networkName, targets, derivationPath);
    }

    function configureLzDvns(string memory networkName, string memory targetName, string memory derivationPath) public {
        string[] memory targets = new string[](1);
        targets[0] = targetName;
        configureLzDvnsAll(networkName, targets, derivationPath);
    }

    //----------------------------------------------------------------------------------------------
    // Internal: collect calls
    //----------------------------------------------------------------------------------------------

    /// @dev Collects all OpsGuardian.wire + initAdapters calls across all targets.
    ///      Skips targets where quorum is already set (already wired).
    function _collectWireCalls(EnvConfig memory source, string[] memory targetNames)
        internal
        view
        returns (address[] memory targets, bytes[] memory datas)
    {
        address opsGuardian = source.contracts.opsGuardian;

        // Over-allocate: max 5 calls per target (4 adapters + 1 initAdapters)
        targets = new address[](targetNames.length * 5);
        datas = new bytes[](targetNames.length * 5);
        uint256 idx;

        for (uint256 t; t < targetNames.length; t++) {
            EnvConfig memory target = Env.load(targetNames[t]);
            uint16 centrifugeId = target.network.centrifugeId;

            if (IMultiAdapter(source.contracts.multiAdapter).quorum(centrifugeId, PoolId.wrap(0)) != 0) {
                continue; // Already wired, skip
            }

            Connection memory conn = _findTargetConnection(source, targetNames[t]);

            IAdapter[] memory adapters = new IAdapter[](4);
            uint256 adapterCount;

            if (conn.layerZero) {
                address lzAdapter = source.contracts.layerZeroAdapter;
                require(lzAdapter != address(0), "LayerZero adapter not configured for source network");
                targets[idx] = opsGuardian;
                datas[idx] = abi.encodeCall(
                    IOpsGuardian.wire,
                    (
                        lzAdapter,
                        centrifugeId,
                        abi.encode(target.adapters.layerZero.layerZeroEid, target.contracts.layerZeroAdapter)
                    )
                );
                idx++;
                adapters[adapterCount++] = IAdapter(lzAdapter);
            }

            if (conn.wormhole) {
                address wormholeAdapter = source.contracts.wormholeAdapter;
                require(wormholeAdapter != address(0), "Wormhole adapter not configured for source network");
                targets[idx] = opsGuardian;
                datas[idx] = abi.encodeCall(
                    IOpsGuardian.wire,
                    (
                        wormholeAdapter,
                        centrifugeId,
                        abi.encode(target.adapters.wormhole.wormholeId, target.contracts.wormholeAdapter)
                    )
                );
                idx++;
                adapters[adapterCount++] = IAdapter(wormholeAdapter);
            }

            if (conn.axelar) {
                address axelarAdapter = source.contracts.axelarAdapter;
                require(axelarAdapter != address(0), "Axelar adapter not configured for source network");
                targets[idx] = opsGuardian;
                datas[idx] = abi.encodeCall(
                    IOpsGuardian.wire,
                    (
                        axelarAdapter,
                        centrifugeId,
                        abi.encode(target.adapters.axelar.axelarId, vm.toString(target.contracts.axelarAdapter))
                    )
                );
                idx++;
                adapters[adapterCount++] = IAdapter(axelarAdapter);
            }

            if (conn.chainlink) {
                address chainlinkAdapter = source.contracts.chainlinkAdapter;
                require(chainlinkAdapter != address(0), "Chainlink adapter not configured for source network");
                targets[idx] = opsGuardian;
                datas[idx] = abi.encodeCall(
                    IOpsGuardian.wire,
                    (
                        chainlinkAdapter,
                        centrifugeId,
                        abi.encode(target.adapters.chainlink.chainSelector, target.contracts.chainlinkAdapter)
                    )
                );
                idx++;
                adapters[adapterCount++] = IAdapter(chainlinkAdapter);
            }

            // Trim adapters to actual count
            IAdapter[] memory trimmedAdapters = new IAdapter[](adapterCount);
            for (uint256 i; i < adapterCount; i++) {
                trimmedAdapters[i] = adapters[i];
            }

            targets[idx] = opsGuardian;
            datas[idx] = abi.encodeCall(
                IOpsGuardian.initAdapters,
                (centrifugeId, trimmedAdapters, conn.threshold, uint8(adapterCount)) /* no recovery adapter */
            );
            idx++;
        }

        // Trim arrays to actual size
        assembly {
            mstore(targets, idx)
            mstore(datas, idx)
        }
    }

    /// @dev Collects all LZ DVN config calls (setSendLibrary, setReceiveLibrary, setConfig x2)
    ///      across all targets. Skips targets without a LayerZero connection.
    function _collectDvnCalls(EnvConfig memory source, string[] memory targetNames)
        internal
        view
        returns (address[] memory targets, bytes[] memory datas)
    {
        address lzAdapter = source.contracts.layerZeroAdapter;
        if (lzAdapter == address(0)) return (targets, datas);

        ILayerZeroEndpointV2Like lzEndpoint = ILayerZeroEndpointV2Like(address(LayerZeroAdapter(lzAdapter).endpoint()));
        address endpoint = address(lzEndpoint);

        // Over-allocate: 4 calls per target
        targets = new address[](targetNames.length * 4);
        datas = new bytes[](targetNames.length * 4);
        uint256 idx;

        for (uint256 t; t < targetNames.length; t++) {
            Connection memory conn = _findTargetConnection(source, targetNames[t]);
            if (!conn.layerZero) continue;

            EnvConfig memory target = Env.load(targetNames[t]);
            uint32 targetEid = target.adapters.layerZero.layerZeroEid;

            SetConfigParam[] memory params = new SetConfigParam[](1);
            params[0] = _buildLzConfigParam(source, targetEid);

            address sendLib = lzEndpoint.defaultSendLibrary(targetEid);
            address recvLib = lzEndpoint.defaultReceiveLibrary(targetEid);
            require(
                sendLib != address(0) && recvLib != address(0), "LZ default libraries not configured for target EID"
            );

            targets[idx] = endpoint;
            datas[idx] = abi.encodeCall(ILayerZeroEndpointV2Like.setSendLibrary, (lzAdapter, targetEid, sendLib));
            idx++;

            targets[idx] = endpoint;
            datas[idx] = abi.encodeCall(ILayerZeroEndpointV2Like.setReceiveLibrary, (lzAdapter, targetEid, recvLib, 0));
            idx++;

            targets[idx] = endpoint;
            datas[idx] = abi.encodeCall(ILayerZeroEndpointV2Like.setConfig, (lzAdapter, sendLib, params));
            idx++;

            targets[idx] = endpoint;
            datas[idx] = abi.encodeCall(ILayerZeroEndpointV2Like.setConfig, (lzAdapter, recvLib, params));
            idx++;
        }

        // Trim arrays to actual size
        assembly {
            mstore(targets, idx)
            mstore(datas, idx)
        }
    }

    //----------------------------------------------------------------------------------------------
    // Internal: helpers
    //----------------------------------------------------------------------------------------------

    /// @dev Proposes a batched Safe transaction (production) or executes calls directly (tests).
    ///      Empty derivationPath = direct call mode (tests); non-empty = Safe proposal mode (production).
    function _batchCall(
        Safe.Client storage safeClient,
        address safeAddr,
        address[] memory targets,
        bytes[] memory datas,
        string memory derivationPath
    ) internal {
        if (bytes(derivationPath).length > 0) {
            safeClient.initialize(safeAddr);
            (address to, bytes memory batchData) = safeClient.getProposeTransactionsTargetAndData(targets, datas);
            bytes memory signature =
                safeClient.sign(to, batchData, Enum.Operation.DelegateCall, msg.sender, derivationPath);
            safeClient.proposeTransactionsWithSignature(targets, datas, msg.sender, signature);
        } else {
            for (uint256 i; i < targets.length; i++) {
                (bool success, bytes memory returnData) = targets[i].call(datas[i]);
                if (!success) assembly { revert(add(returnData, 32), mload(returnData)) }
            }
        }
    }

    function _buildLzConfigParam(EnvConfig memory source, uint32 destEid)
        internal
        pure
        returns (SetConfigParam memory)
    {
        bytes memory encodedUln = abi.encode(
            UlnConfig({
                confirmations: source.adapters.layerZero.blockConfirmations,
                requiredDVNCount: uint8(source.adapters.layerZero.dvns.length),
                optionalDVNCount: type(uint8).max, // NIL_DVN_COUNT: explicitly no optional DVNs
                optionalDVNThreshold: 0,
                requiredDVNs: source.adapters.layerZero.dvns,
                optionalDVNs: new address[](0)
            })
        );
        return SetConfigParam(destEid, ULN_CONFIG_TYPE, encodedUln);
    }

    function _findTargetConnection(EnvConfig memory source, string memory targetName)
        internal
        view
        returns (Connection memory)
    {
        Connection[] memory connections = source.network.connections();
        for (uint256 i = 0; i < connections.length; i++) {
            if (keccak256(bytes(connections[i].network)) == keccak256(bytes(targetName))) {
                return connections[i];
            }
        }
        revert("No connection configured between source and target");
    }
}
