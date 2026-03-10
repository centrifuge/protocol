// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {ERC20} from "../../../src/misc/ERC20.sol";
import {ISpoke} from "../../../src/core/spoke/interfaces/ISpoke.sol";
import {LayerZeroAdapter} from "../../../src/adapters/LayerZeroAdapter.sol";
import {ChainlinkAdapter} from "../../../src/adapters/ChainlinkAdapter.sol";

import {Env, EnvConfig} from "../../../script/utils/EnvConfig.s.sol";
import {WireToNewNetwork} from "../../../script/WireToNewNetwork.s.sol";

import "forge-std/Test.sol";

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

        vm.startPrank(source.network.opsAdmin);
        wire(networkName, targetName, "");
        vm.stopPrank();

        vm.startPrank(source.network.protocolAdmin);
        configureLzDvns(networkName, targetName, "");
        vm.stopPrank();

        ERC20 asset = new ERC20(18);
        asset.file("name", "Test Token");
        asset.file("symbol", "TEST");

        vm.deal(address(this), 1 ether);
        vm.recordLogs();

        ISpoke(source.contracts.spoke).registerAsset{value: 0.1 ether}(
            target.network.centrifugeId, address(asset), 0, address(this)
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertLayerZeroEvent(source, target, logs);
        _assertChainlinkEvent(source, target, logs);
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

    function testWirePharos() external {
        _testCase("pharos");
    }

    // function testWireMonad() external {
    //     _testCase("monad");
    // }
}
