// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "../src/core/messaging/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../src/core/messaging/interfaces/IMultiAdapter.sol";
import {IOpsGuardian} from "../src/admin/interfaces/IOpsGuardian.sol";
import {PoolId} from "../src/core/types/PoolId.sol";
import {LayerZeroAdapter} from "../src/adapters/LayerZeroAdapter.sol";
import {
    SetConfigParam,
    UlnConfig,
    ILayerZeroEndpointV2Like
} from "../src/deployment/interfaces/ILayerZeroEndpointV2Like.sol";

import "forge-std/Script.sol";

import {Safe, Enum} from "safe-utils/Safe.sol";

import {Env, EnvConfig, Connection} from "./utils/EnvConfig.s.sol";

/// @title WireToNewNetwork
/// @notice Proposes OpsGuardian.wire and initAdapters transactions via the ops Safe
///         to wire a chain to a target chain.
/// @dev Run this script on each non-target mainnet chain that needs to be wired to a target chain.
///      The target chain was deployed after the other chains and has already been wired to them,
///      but the reciprocal wiring (other chains -> target chain) still needs to be set up.
///
///      Set NETWORK env var to the source chain name (e.g., "ethereum", "base", "arbitrum").
///      The script reads adapter configuration from env/<network>.json and
///      env/connections/mainnet.json to determine which adapters to wire.
///
///      Example usage:
///        NETWORK=ethereum forge script script/WireToNewNetwork.s.sol --rpc-url $ETH_RPC_URL --broadcast
///        NETWORK=base forge script script/WireToNewNetwork.s.sol --rpc-url $BASE_RPC_URL --broadcast
contract WireToNewNetwork is Script {
    using Safe for *;

    string constant LEDGER_DERIVATION_PATH = "m/44'/60'/0'/0/0";
    uint32 constant ULN_CONFIG_TYPE = 2;

    Safe.Client safe;
    uint256 nonce;
    Safe.Client protocolSafe;
    uint256 protocolNonce;
    string derivationPath;
    address opsGuardian;

    function run() external {
        vm.startBroadcast();
        string memory networkName = vm.envString("NETWORK");
        string memory targetName = vm.envString("TARGET");
        wire(networkName, targetName, LEDGER_DERIVATION_PATH);
        configureLzDvns(networkName, targetName, LEDGER_DERIVATION_PATH);
        vm.stopBroadcast();
    }

    function wire(string memory networkName, string memory targetName, string memory derivationPath_) public {
        EnvConfig memory source = Env.load(networkName);
        EnvConfig memory target = Env.load(targetName);

        require(
            IMultiAdapter(source.contracts.multiAdapter).quorum(target.network.centrifugeId, PoolId.wrap(0)) == 0,
            "Target already wired"
        );

        Connection memory targetConn = _findTargetConnection(source, targetName);
        derivationPath = derivationPath_;
        opsGuardian = source.contracts.opsGuardian;

        if (bytes(derivationPath).length > 0) {
            safe.initialize(source.network.opsAdmin);
            nonce = safe.getNonce();
        }

        uint256 adapterCount;
        if (targetConn.layerZero) adapterCount++;
        if (targetConn.wormhole) adapterCount++;
        if (targetConn.axelar) adapterCount++;
        if (targetConn.chainlink) adapterCount++;

        IAdapter[] memory adapters = new IAdapter[](adapterCount);
        uint256 idx;

        if (targetConn.layerZero) {
            address lzAdapter = source.contracts.layerZeroAdapter;
            bytes memory data = abi.encode(target.adapters.layerZero.layerZeroEid, target.contracts.layerZeroAdapter);
            _call(abi.encodeCall(IOpsGuardian.wire, (lzAdapter, target.network.centrifugeId, data)));
            adapters[idx++] = IAdapter(lzAdapter);
        }

        if (targetConn.wormhole) {
            address wormholeAdapter = source.contracts.wormholeAdapter;
            bytes memory data = abi.encode(target.adapters.wormhole.wormholeId, target.contracts.wormholeAdapter);
            _call(abi.encodeCall(IOpsGuardian.wire, (wormholeAdapter, target.network.centrifugeId, data)));
            adapters[idx++] = IAdapter(wormholeAdapter);
        }

        if (targetConn.axelar) {
            address axelarAdapter = source.contracts.axelarAdapter;
            bytes memory data = abi.encode(target.adapters.axelar.axelarId, target.contracts.axelarAdapter);
            _call(abi.encodeCall(IOpsGuardian.wire, (axelarAdapter, target.network.centrifugeId, data)));
            adapters[idx++] = IAdapter(axelarAdapter);
        }

        if (targetConn.chainlink) {
            address chainlinkAdapter = source.contracts.chainlinkAdapter;
            bytes memory data = abi.encode(target.adapters.chainlink.chainSelector, target.contracts.chainlinkAdapter);
            _call(abi.encodeCall(IOpsGuardian.wire, (chainlinkAdapter, target.network.centrifugeId, data)));
            adapters[idx++] = IAdapter(chainlinkAdapter);
        }

        _call(
            abi.encodeCall(
                IOpsGuardian.initAdapters,
                (target.network.centrifugeId, adapters, targetConn.threshold, uint8(adapters.length))
            )
        );
    }

    function configureLzDvns(string memory networkName, string memory targetName, string memory derivationPath_)
        public
    {
        EnvConfig memory source = Env.load(networkName);
        EnvConfig memory target = Env.load(targetName);

        Connection memory targetConn = _findTargetConnection(source, targetName);
        if (!targetConn.layerZero) return;

        derivationPath = derivationPath_;

        if (bytes(derivationPath).length > 0) {
            protocolSafe.initialize(source.network.protocolAdmin);
            protocolNonce = protocolSafe.getNonce();
        }

        _configureLzDvns(source, target);
    }

    function _configureLzDvns(EnvConfig memory source, EnvConfig memory target) internal {
        address lzAdapter = source.contracts.layerZeroAdapter;
        ILayerZeroEndpointV2Like lzEndpoint = ILayerZeroEndpointV2Like(address(LayerZeroAdapter(lzAdapter).endpoint()));
        uint32 targetEid = target.adapters.layerZero.layerZeroEid;

        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = _buildLzConfigParam(source, targetEid);

        address sendLib = lzEndpoint.defaultSendLibrary(targetEid);
        address recvLib = lzEndpoint.defaultReceiveLibrary(targetEid);
        address endpoint = address(lzEndpoint);

        if (bytes(derivationPath).length > 0) {
            _callProtocol(
                endpoint, abi.encodeCall(ILayerZeroEndpointV2Like.setSendLibrary, (lzAdapter, targetEid, sendLib))
            );
            _callProtocol(
                endpoint, abi.encodeCall(ILayerZeroEndpointV2Like.setReceiveLibrary, (lzAdapter, targetEid, recvLib, 0))
            );
            _callProtocol(endpoint, abi.encodeCall(ILayerZeroEndpointV2Like.setConfig, (lzAdapter, sendLib, params)));
            _callProtocol(endpoint, abi.encodeCall(ILayerZeroEndpointV2Like.setConfig, (lzAdapter, recvLib, params)));
        } else {
            lzEndpoint.setSendLibrary(lzAdapter, targetEid, sendLib);
            lzEndpoint.setReceiveLibrary(lzAdapter, targetEid, recvLib, 0);
            lzEndpoint.setConfig(lzAdapter, sendLib, params);
            lzEndpoint.setConfig(lzAdapter, recvLib, params);
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
                optionalDVNCount: type(uint8).max,
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

    function _callProtocol(address target, bytes memory data) internal {
        Safe.ExecTransactionParams memory params = Safe.ExecTransactionParams({
            to: target,
            value: 0,
            data: data,
            operation: Enum.Operation.Call,
            sender: msg.sender,
            signature: protocolSafe.sign(target, data, Enum.Operation.Call, msg.sender, protocolNonce, derivationPath),
            nonce: protocolNonce
        });
        protocolSafe.proposeTransaction(params);
        protocolNonce++;
    }

    function _call(bytes memory data) internal {
        if (bytes(derivationPath).length > 0) {
            Safe.ExecTransactionParams memory params = Safe.ExecTransactionParams({
                to: opsGuardian,
                value: 0,
                data: data,
                operation: Enum.Operation.Call,
                sender: msg.sender,
                signature: safe.sign(opsGuardian, data, Enum.Operation.Call, msg.sender, nonce, derivationPath),
                nonce: nonce
            });
            safe.proposeTransaction(params);
            nonce++;
        } else {
            (bool success, bytes memory returnData) = opsGuardian.call(data);
            if (!success) assembly { revert(add(returnData, 32), mload(returnData)) }
        }
    }
}
