// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../src/core/types/PoolId.sol";
import {IAdapter} from "../../src/core/messaging/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../../src/core/messaging/interfaces/IMultiAdapter.sol";

import {IOpsGuardian} from "../../src/admin/interfaces/IOpsGuardian.sol";

import "forge-std/Script.sol";

import {Safe, Enum} from "safe-utils/Safe.sol";
import {ledgerDerivationPath} from "../utils/Admin.s.sol";
import {LayerZeroAdapter} from "../../src/adapters/LayerZeroAdapter.sol";
import {Env, EnvConfig, EnvConfigLib, Connection} from "../utils/EnvConfig.s.sol";
import {SetConfigParam, ILayerZeroEndpointV2Like} from "../../src/deployment/interfaces/ILayerZeroEndpointV2Like.sol";

/// @title WireToNewNetwork
/// @notice Proposes batched OpsGuardian.wire/setAdapters and LZ DVN config transactions via Safe
///         to wire a source chain to one or more target chains.
/// @dev Run this script on each source chain that needs to be wired to target chain(s).
///      All ops Safe calls (wire + setAdapters) are batched into a single proposal.
///      All protocol Safe calls (LZ DVN config) are batched into a single proposal.
///      This minimizes signing rounds to at most 2 per source chain.
///
///      The source chain is the one `--rpc-url` points at. Set TARGETS to comma-separated target chain
///      names (e.g., "monad,pharos"), each of which needs an env/<name>.json.
///
///      Set LEDGER_DERIVATION_PATH to override the default path, which only matches one
///      signer's device. The proposal is rejected unless --sender equals the address it derives.
///
///      Requires --ffi (safe-utils signs via `cast wallet sign --ledger`). Do not pass --ledger to
///      forge itself: it holds the device transport and the FFI signing call then fails.
///
///      The protocol batch must be executed before the ops batch on each source chain, so prefer the
///      staged entry points: --sig "runProtocol()" first, then --sig "runOps()" once phase 1 has landed.
///      Neither phase is safe to re-propose after it executes: wireAll skips already-wired targets, but
///      configureLzDvnsAll has no such guard and setSendLibrary reverts on an unchanged value.
///
///      Example usage:
///        TARGETS=monad,pharos forge script script/ops/WireToNewNetwork.s.sol --sig "runProtocol()"
///            --rpc-url ethereum --sender $SAFE_OWNER --ffi --broadcast
///        TARGETS=monad,pharos forge script script/ops/WireToNewNetwork.s.sol --sig "runOps()"
///            --rpc-url ethereum --sender $SAFE_OWNER --ffi --broadcast
contract WireToNewNetwork is Script {
    using Safe for *;

    PoolId constant GLOBAL_POOL = PoolId.wrap(0);

    Safe.Client safe;
    Safe.Client protocolSafe;

    /// @notice Proposes both batches at once. The protocol batch must still be *executed* before the ops
    ///         batch: until the LZ libraries are pinned, the endpoint resolves the target EID to its
    ///         default ULN config, and an EID no OApp has used yet resolves to the DeadDVN sentinel, so
    ///         every send reverts. Prefer runProtocol/runOps, which stage the two phases so the ops Safe
    ///         cannot front-run the slower protocol Safe.
    function run() external {
        vm.startBroadcast();
        string memory networkName = Env.detect();
        string[] memory targetNames = vm.envString("TARGETS", ",");
        configureLzDvnsAll(networkName, targetNames, ledgerDerivationPath());
        wireAll(networkName, targetNames, ledgerDerivationPath());
        vm.stopBroadcast();
    }

    /// @notice Phase 1: propose the protocol Safe batch (LZ libraries + ULN config) only.
    function runProtocol() external {
        vm.startBroadcast();
        configureLzDvnsAll(Env.detect(), vm.envString("TARGETS", ","), ledgerDerivationPath());
        vm.stopBroadcast();
    }

    /// @notice Phase 2: propose the ops Safe batch (adapter wiring + adapter set) only. Run once the
    ///         phase 1 batch is executed, never before.
    function runOps() external {
        vm.startBroadcast();
        wireAll(Env.detect(), vm.envString("TARGETS", ","), ledgerDerivationPath());
        vm.stopBroadcast();
    }

    //----------------------------------------------------------------------------------------------
    // Multi-target batched entry points
    //----------------------------------------------------------------------------------------------

    /// @notice Wire adapters for multiple targets in a single batched ops Safe proposal.
    ///         Targets already wired (quorum > 0) are silently skipped.
    function wireAll(string memory networkName, string[] memory targetNames, string memory derivationPath) public {
        EnvConfig memory source = Env.load(networkName);
        (address[] memory targets, bytes[] memory data) = _collectWireCalls(source, targetNames);
        if (targets.length == 0) return;
        _batchCall(safe, source.network.opsAdmin, targets, data, derivationPath);
    }

    /// @notice Configure LZ DVNs for multiple targets in a single batched protocol Safe proposal.
    ///         Targets without a LayerZero connection are silently skipped.
    function configureLzDvnsAll(string memory networkName, string[] memory targetNames, string memory derivationPath)
        public
    {
        EnvConfig memory source = Env.load(networkName);
        (address[] memory targets, bytes[] memory data) = _collectDvnCalls(source, targetNames);
        if (targets.length == 0) return;
        _batchCall(protocolSafe, source.network.protocolAdmin, targets, data, derivationPath);
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

    /// @dev Collects all OpsGuardian.wire + setAdapters calls across all targets.
    function _collectWireCalls(EnvConfig memory source, string[] memory targetNames)
        internal
        view
        returns (address[] memory targets, bytes[] memory data)
    {
        address opsGuardian = source.contracts.opsGuardian;

        // Over-allocate: max 5 calls per target (4 adapters + 1 setAdapters)
        targets = new address[](targetNames.length * 5);
        data = new bytes[](targetNames.length * 5);
        uint256 idx;

        for (uint256 t; t < targetNames.length; t++) {
            EnvConfig memory target = Env.load(targetNames[t]);
            uint16 centrifugeId = target.network.centrifugeId;

            if (IMultiAdapter(source.contracts.multiAdapter).quorum(centrifugeId, GLOBAL_POOL) != 0) {
                console.log("Skipping already-wired target:", targetNames[t]);
                continue;
            }

            Connection memory conn = _findTargetConnection(source, targetNames[t]);

            IAdapter[] memory adapters = new IAdapter[](4);
            uint256 adapterCount;

            if (conn.layerZero) {
                address lzAdapter = source.contracts.layerZeroAdapter;
                require(lzAdapter != address(0), "LayerZero adapter not configured for source network");
                targets[idx] = opsGuardian;
                data[idx] = abi.encodeCall(
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

            if (conn.axelar) {
                address axelarAdapter = source.contracts.axelarAdapter;
                require(axelarAdapter != address(0), "Axelar adapter not configured for source network");
                targets[idx] = opsGuardian;
                data[idx] = abi.encodeCall(
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
                data[idx] = abi.encodeCall(
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

            if (conn.hyperlane) {
                address hyperlaneAdapter = source.contracts.hyperlaneAdapter;
                require(hyperlaneAdapter != address(0), "Hyperlane adapter not configured for source network");
                targets[idx] = opsGuardian;
                data[idx] = abi.encodeCall(
                    IOpsGuardian.wire,
                    (
                        hyperlaneAdapter,
                        centrifugeId,
                        abi.encode(target.adapters.hyperlane.hyperlaneId, target.contracts.hyperlaneAdapter)
                    )
                );
                idx++;
                adapters[adapterCount++] = IAdapter(hyperlaneAdapter);
            }

            // Trim adapters to actual count
            IAdapter[] memory trimmedAdapters = new IAdapter[](adapterCount);
            for (uint256 i; i < adapterCount; i++) {
                trimmedAdapters[i] = adapters[i];
            }

            targets[idx] = opsGuardian;
            data[idx] = abi.encodeCall(IOpsGuardian.setAdapters, (centrifugeId, trimmedAdapters, conn.threshold));
            idx++;
        }

        // Safe: idx <= original length; only shrinks array length
        assembly {
            mstore(targets, idx)
            mstore(data, idx)
        }
    }

    /// @dev Collects all LZ DVN config calls (setSendLibrary, setReceiveLibrary, setConfig x2)
    ///      across all targets. Skips targets without a LayerZero connection.
    function _collectDvnCalls(EnvConfig memory source, string[] memory targetNames)
        internal
        view
        returns (address[] memory targets, bytes[] memory data)
    {
        address lzAdapter = source.contracts.layerZeroAdapter;
        if (lzAdapter == address(0)) return (new address[](0), new bytes[](0));

        ILayerZeroEndpointV2Like lzEndpoint = ILayerZeroEndpointV2Like(address(LayerZeroAdapter(lzAdapter).endpoint()));
        address endpoint = address(lzEndpoint);

        // Over-allocate: 4 calls per target
        targets = new address[](targetNames.length * 4);
        data = new bytes[](targetNames.length * 4);
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
            data[idx] = abi.encodeCall(ILayerZeroEndpointV2Like.setSendLibrary, (lzAdapter, targetEid, sendLib));
            idx++;

            targets[idx] = endpoint;
            data[idx] = abi.encodeCall(ILayerZeroEndpointV2Like.setReceiveLibrary, (lzAdapter, targetEid, recvLib, 0));
            idx++;

            targets[idx] = endpoint;
            data[idx] = abi.encodeCall(ILayerZeroEndpointV2Like.setConfig, (lzAdapter, sendLib, params));
            idx++;

            targets[idx] = endpoint;
            data[idx] = abi.encodeCall(ILayerZeroEndpointV2Like.setConfig, (lzAdapter, recvLib, params));
            idx++;
        }

        // Safe: idx <= original length; only shrinks array length
        assembly {
            mstore(targets, idx)
            mstore(data, idx)
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
        bytes[] memory data,
        string memory derivationPath
    ) internal {
        if (bytes(derivationPath).length > 0) {
            safeClient.initialize(safeAddr);
            (address to, bytes memory batchData) = safeClient.getProposeTransactionsTargetAndData(targets, data);
            uint256 nonce = safeClient.getNonce();
            bytes memory signature =
                safeClient.sign(to, batchData, Enum.Operation.DelegateCall, msg.sender, derivationPath);
            _assertSignerIsSender(
                safeClient.getSafeTxHash(to, 0, batchData, Enum.Operation.DelegateCall, nonce),
                signature,
                derivationPath
            );
            safeClient.proposeTransactionsWithSignature(targets, data, msg.sender, signature);
        } else {
            for (uint256 i; i < targets.length; i++) {
                (bool success, bytes memory returnData) = targets[i].call(data[i]);
                if (!success) assembly { revert(add(returnData, 32), mload(returnData)) }
            }
        }
    }

    /// @dev A derivation path that resolves to a non-owner is otherwise only rejected by the
    ///      transaction service, as an HTTP 422, after the device has already signed. Recover locally
    ///      and name both addresses instead.
    function _assertSignerIsSender(bytes32 safeTxHash, bytes memory signature, string memory derivationPath)
        internal
        view
    {
        require(signature.length == 65, "Unexpected signature length");

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        address recovered = ecrecover(safeTxHash, v, r, s);
        require(
            recovered == msg.sender,
            string.concat(
                "Derivation path ",
                derivationPath,
                " signs as ",
                vm.toString(recovered),
                " but --sender is ",
                vm.toString(msg.sender)
            )
        );
    }

    function _buildLzConfigParam(EnvConfig memory source, uint32 destEid)
        internal
        pure
        returns (SetConfigParam memory)
    {
        return SetConfigParam(
            destEid, EnvConfigLib.ULN_CONFIG_TYPE, EnvConfigLib.encodeUlnConfig(source.adapters.layerZero)
        );
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
