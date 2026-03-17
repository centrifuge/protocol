// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "../../../src/misc/ERC20.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {ISpoke} from "../../../src/core/spoke/interfaces/ISpoke.sol";
import {IMultiAdapter} from "../../../src/core/messaging/interfaces/IMultiAdapter.sol";

import {Env, EnvConfig} from "../../../script/utils/EnvConfig.s.sol";
import {WireToNewNetwork} from "../../../script/WireToNewNetwork.s.sol";
import {Connection} from "../../../script/utils/EnvConnectionsConfig.s.sol";

import "forge-std/Test.sol";

import {ChainlinkAdapter} from "../../../src/adapters/ChainlinkAdapter.sol";
import {LayerZeroAdapter} from "../../../src/adapters/LayerZeroAdapter.sol";

/// @title  WireToNewNetworkForkTest
/// @notice Fork test that runs WireToNewNetwork.wire() and verifies the underlying bridge
///         contracts emit events with the correct destination EID/chain ID and receiving adapter address.
/// @dev    Extends WireToNewNetwork so the same wiring logic is tested end-to-end.
///         Run per-source-chain; each test forks that chain and simulates the wiring.
contract WireToNewNetworkForkTest is WireToNewNetwork, Test {
    using CastLib for address;

    receive() external payable {}

    function _testCase(string memory networkName) internal {
        EnvConfig memory source = Env.load(networkName);
        string memory targetName = "monad";
        EnvConfig memory target = Env.load(targetName);

        vm.createSelectFork(source.network.rpcUrl());

        assertEq(
            IMultiAdapter(source.contracts.multiAdapter).quorum(target.network.centrifugeId, GLOBAL_POOL),
            0,
            "Target already wired, test is ineffective"
        );

        vm.startPrank(source.network.opsAdmin);
        wire(networkName, targetName, "");
        vm.stopPrank();

        vm.startPrank(source.network.protocolAdmin);
        configureLzDvns(networkName, targetName, "");
        vm.stopPrank();

        Connection memory targetConn = _findTargetConnection(source, targetName);

        IMultiAdapter multiAdapter = IMultiAdapter(source.contracts.multiAdapter);
        assertGt(multiAdapter.quorum(target.network.centrifugeId, GLOBAL_POOL), 0, "Quorum not set");
        assertEq(
            multiAdapter.threshold(target.network.centrifugeId, GLOBAL_POOL), targetConn.threshold, "Threshold not set"
        );

        ERC20 asset = new ERC20(18);
        asset.file("name", "Test Token");
        asset.file("symbol", "TEST");

        vm.deal(address(this), 10 ether);
        vm.recordLogs();

        ISpoke(source.contracts.spoke).registerAsset{value: 10 ether}(
            target.network.centrifugeId, address(asset), 0, address(this)
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertLayerZeroEvent(source, target, logs);
        if (targetConn.chainlink) _assertChainlinkEvent(source, target, logs);
    }

    /// @dev Checks the LZ endpoint emits PacketSent with Monad's EID and Monad's LZ adapter as the receiver.
    ///
    ///      LZ V2 packet header layout (81 bytes):
    ///        version(1) | nonce(8) | srcEid(4) | sender(32) | dstEid(4) | receiver(32)
    ///      dstEid is at byte offset 45; receiver is at byte offset 49.
    function _assertLayerZeroEvent(EnvConfig memory source, EnvConfig memory target, Vm.Log[] memory logs)
        internal
        view
    {
        address lzEndpoint = address(LayerZeroAdapter(source.contracts.layerZeroAdapter).endpoint());

        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == lzEndpoint && logs[i].topics[0] == keccak256("PacketSent(bytes,bytes,address)")) {
                (bytes memory packet,,) = abi.decode(logs[i].data, (bytes, bytes, address));

                uint32 dstEid;
                bytes32 receiver;
                assembly {
                    let base := add(packet, 0x20)
                    dstEid := shr(224, mload(add(base, 45)))
                    receiver := mload(add(base, 49))
                }

                assertEq(dstEid, target.adapters.layerZero.layerZeroEid, "Wrong LZ destination EID");
                assertEq(receiver, target.contracts.layerZeroAdapter.toBytes32LeftPadded(), "Wrong LZ receiver");
                found = true;
                break;
            }
        }
        assertTrue(found, "PacketSent not emitted by LZ endpoint");
    }

    /// @dev Checks the MultiAdapter emits SendPayload for the Chainlink adapter with a non-zero CCIP messageId,
    ///      confirming the CCIP router accepted the message to Monad's chain selector.
    function _assertChainlinkEvent(EnvConfig memory source, EnvConfig memory target, Vm.Log[] memory logs)
        internal
        view
    {
        address multiAdapter = source.contracts.multiAdapter;
        address chainlinkAdapter = source.contracts.chainlinkAdapter;

        bool found;
        bytes32 sendPayloadTopic =
            keccak256("SendPayload(uint16,bytes32,bytes,address,bytes32,uint256,uint256,address)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == multiAdapter && logs[i].topics[0] == sendPayloadTopic) {
                // Non-indexed: bytes payload, IAdapter adapter, bytes32 adapterData, uint256 gasLimit, uint256 gasPaid, address refund
                (, address adapter, bytes32 adapterData,,,) =
                    abi.decode(logs[i].data, (bytes, address, bytes32, uint256, uint256, address));

                if (adapter == chainlinkAdapter) {
                    assertNotEq(adapterData, bytes32(0), "CCIP send returned empty messageId");
                    (uint64 chainSelector, address remoteAdapter) =
                        ChainlinkAdapter(chainlinkAdapter).destinations(target.network.centrifugeId);
                    assertEq(
                        chainSelector,
                        target.adapters.chainlink.chainSelector,
                        "Wrong Chainlink destination chain selector"
                    );
                    assertEq(remoteAdapter, target.contracts.chainlinkAdapter, "Wrong Chainlink destination adapter");
                    found = true;
                    break;
                }
            }
        }
        assertTrue(found, "SendPayload not emitted by MultiAdapter for Chainlink");
    }

    function testWireEthereum() external {
        _testCase("ethereum");
    }

    function testWireBase() external {
        _testCase("base");
    }

    function testWireArbitrum() external {
        _testCase("arbitrum");
    }

    function testWireAvalanche() external {
        _testCase("avalanche");
    }

    function testWireBnbSmartChain() external {
        _testCase("bnb-smart-chain");
    }

    function testWireHyperEvm() external {
        _testCase("hyper-evm");
    }

    function testWireOptimism() external {
        _testCase("optimism");
    }

    function testWirePlume() external {
        _testCase("plume");
    }

    /// @notice Tests that wireAll + configureLzDvnsAll correctly batch multiple targets
    ///         into a single execution, wiring both monad and pharos from ethereum in one call.
    function testBatchWireEthereum() external {
        string memory networkName = "ethereum";
        EnvConfig memory source = Env.load(networkName);

        vm.createSelectFork(source.network.rpcUrl());

        string[] memory targetNames = new string[](2);
        targetNames[0] = "monad";
        targetNames[1] = "pharos";

        // Batch wire both targets in a single call
        vm.startPrank(source.network.opsAdmin);
        wireAll(networkName, targetNames, "");
        vm.stopPrank();

        // Batch configure DVNs for both targets in a single call
        vm.startPrank(source.network.protocolAdmin);
        configureLzDvnsAll(networkName, targetNames, "");
        vm.stopPrank();

        // Verify both targets are wired with correct quorum/threshold
        IMultiAdapter ma = IMultiAdapter(source.contracts.multiAdapter);
        for (uint256 i; i < targetNames.length; i++) {
            EnvConfig memory target = Env.load(targetNames[i]);
            Connection memory conn = _findTargetConnection(source, targetNames[i]);

            uint16 cid = target.network.centrifugeId;
            assertGt(ma.quorum(cid, GLOBAL_POOL), 0, string.concat("Quorum not set for ", targetNames[i]));
            assertEq(
                ma.threshold(cid, GLOBAL_POOL), conn.threshold, string.concat("Wrong threshold for ", targetNames[i])
            );
        }

        // Verify cross-chain message can be sent to monad (the first target)
        EnvConfig memory monad = Env.load("monad");
        ERC20 asset = new ERC20(18);
        asset.file("name", "Test Token");
        asset.file("symbol", "TEST");

        vm.deal(address(this), 20 ether);
        vm.recordLogs();

        ISpoke(source.contracts.spoke).registerAsset{value: 10 ether}(
            monad.network.centrifugeId, address(asset), 0, address(this)
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertLayerZeroEvent(source, monad, logs);

        Connection memory monadConn = _findTargetConnection(source, "monad");
        if (monadConn.chainlink) _assertChainlinkEvent(source, monad, logs);

        EnvConfig memory pharos = Env.load("pharos");
        vm.recordLogs();

        ISpoke(source.contracts.spoke).registerAsset{value: 10 ether}(
            pharos.network.centrifugeId, address(asset), 0, address(this)
        );

        Vm.Log[] memory pharosLogs = vm.getRecordedLogs();
        _assertLayerZeroEvent(source, pharos, pharosLogs);
    }

    /// @notice Tests that _collectWireCalls and _collectDvnCalls produce exactly one batch each
    ///         for multiple targets, proving a single Safe signature per batch.
    function testCollectCallsBatchesMultipleTargets() external {
        EnvConfig memory source = Env.load("ethereum");
        vm.createSelectFork(source.network.rpcUrl());

        string[] memory targetNames = new string[](2);
        targetNames[0] = "monad";
        targetNames[1] = "pharos";

        _assertWireCallsBatched(source, targetNames);
        _assertDvnCallsBatched(source, targetNames);
    }

    function _assertWireCallsBatched(EnvConfig memory source, string[] memory targetNames) internal view {
        (address[] memory targets, bytes[] memory data) = _collectWireCalls(source, targetNames);

        // Count expected calls: per target = N adapter wire calls + 1 initAdapters
        uint256 expected;
        for (uint256 t; t < targetNames.length; t++) {
            Connection memory conn = _findTargetConnection(source, targetNames[t]);
            if (conn.layerZero) expected++;
            if (conn.wormhole) expected++;
            if (conn.axelar) expected++;
            if (conn.chainlink) expected++;
            expected++; // initAdapters
        }

        assertEq(targets.length, expected, "Wire calls not batched into single array");
        assertEq(data.length, expected, "Wire data count mismatch");

        for (uint256 i; i < targets.length; i++) {
            assertEq(targets[i], source.contracts.opsGuardian, "Wire call target is not opsGuardian");
        }
    }

    function _assertDvnCallsBatched(EnvConfig memory source, string[] memory targetNames) internal view {
        (address[] memory targets, bytes[] memory data) = _collectDvnCalls(source, targetNames);

        // 4 per LZ-enabled target expected
        uint256 expected;
        for (uint256 t; t < targetNames.length; t++) {
            Connection memory conn = _findTargetConnection(source, targetNames[t]);
            if (conn.layerZero) expected += 4;
        }

        assertEq(targets.length, expected, "DVN calls not batched into single array");
        assertEq(data.length, expected, "DVN data count mismatch");

        address lzEndpoint = address(LayerZeroAdapter(source.contracts.layerZeroAdapter).endpoint());
        for (uint256 i; i < targets.length; i++) {
            assertEq(targets[i], lzEndpoint, "DVN call target is not LZ endpoint");
        }
    }

    /// @notice Tests that wireAll silently skips already-wired targets.
    function testBatchWireSkipsAlreadyWired() external {
        string memory networkName = "ethereum";
        EnvConfig memory source = Env.load(networkName);
        vm.createSelectFork(source.network.rpcUrl());

        // Wire monad first (single target)
        vm.startPrank(source.network.opsAdmin);
        wire(networkName, "monad", "");
        vm.stopPrank();

        IMultiAdapter ma = IMultiAdapter(source.contracts.multiAdapter);
        EnvConfig memory monad = Env.load("monad");
        EnvConfig memory pharos = Env.load("pharos");

        uint8 monadQuorum = ma.quorum(monad.network.centrifugeId, GLOBAL_POOL);
        assertGt(monadQuorum, 0, "Monad should be wired");
        assertEq(ma.quorum(pharos.network.centrifugeId, GLOBAL_POOL), 0, "Pharos should not be wired yet");

        // Now batch wire [monad, pharos] -- monad should be skipped
        string[] memory targetNames = new string[](2);
        targetNames[0] = "monad";
        targetNames[1] = "pharos";

        vm.startPrank(source.network.opsAdmin);
        wireAll(networkName, targetNames, "");
        vm.stopPrank();

        // Monad state unchanged, pharos newly wired
        assertEq(ma.quorum(monad.network.centrifugeId, GLOBAL_POOL), monadQuorum, "Monad quorum should be unchanged");
        assertGt(ma.quorum(pharos.network.centrifugeId, GLOBAL_POOL), 0, "Pharos should now be wired");
    }
}
