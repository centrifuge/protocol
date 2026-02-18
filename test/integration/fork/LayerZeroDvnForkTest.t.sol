// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "../../../src/misc/ERC20.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {newAssetId} from "../../../src/core/types/AssetId.sol";
import {ISpoke} from "../../../src/core/spoke/interfaces/ISpoke.sol";
import {IHubRegistry} from "../../../src/core/hub/interfaces/IHubRegistry.sol";

import {Env, EnvConfig} from "../../../script/utils/EnvConfig.s.sol";

import "forge-std/Test.sol";

import {Origin} from "../../../src/adapters/interfaces/ILayerZeroAdapter.sol";
import {ILayerZeroEndpointV2Like} from "../../../src/deployment/interfaces/ILayerZeroEndpointV2Like.sol";

library PacketV1Codec {
    uint256 private constant NONCE_OFFSET = 1;
    uint256 private constant GUID_OFFSET = 81;
    uint256 private constant MESSAGE_OFFSET = 113;

    function nonce(bytes calldata _packet) internal pure returns (uint64) {
        return uint64(bytes8(_packet[NONCE_OFFSET:NONCE_OFFSET + 8]));
    }

    function header(bytes calldata _packet) internal pure returns (bytes calldata) {
        return _packet[0:GUID_OFFSET];
    }

    function guid(bytes calldata _packet) internal pure returns (bytes32) {
        return bytes32(_packet[GUID_OFFSET:MESSAGE_OFFSET]);
    }

    function message(bytes calldata _packet) internal pure returns (bytes calldata) {
        return bytes(_packet[MESSAGE_OFFSET:]);
    }

    function payload(bytes calldata _packet) internal pure returns (bytes calldata) {
        return bytes(_packet[GUID_OFFSET:]);
    }

    function payloadHash(bytes calldata _packet) internal pure returns (bytes32) {
        return keccak256(payload(_packet));
    }
}

interface ILayerZeroEndpointV2Ext is ILayerZeroEndpointV2Like {
    event PacketSent(bytes encodedPayload, bytes options, address sendLibrary);

    function lzReceive(
        Origin calldata _origin,
        address _receiver,
        bytes32 _guid,
        bytes calldata _message,
        bytes calldata _extraData
    ) external payable;
}

contract TestToken is ERC20 {
    constructor() ERC20(8) {}
}

interface IReceiveUln {
    function verify(bytes calldata _packetHeader, bytes32 _payloadHash, uint64 _confirmations) external;
    function commitVerification(bytes calldata _packetHeader, bytes32 _payloadHash) external;
}

/// @title LayerZeroDvnForkTest
/// @notice Send a message end-to-end through the deployed ETH ↔ BASE LayerZero adapters
contract LayerZeroDvnForkTest is Test {
    using CastLib for *;

    EnvConfig ethConfig = Env.load("ethereum");
    EnvConfig baseConfig = Env.load("base");

    ILayerZeroEndpointV2Ext immutable lzEndpoint = ILayerZeroEndpointV2Ext(ethConfig.adapters.layerZero.endpoint);
    uint16 immutable ETH_CENT_ID = ethConfig.network.centrifugeId;
    uint16 immutable BASE_CENT_ID = baseConfig.network.centrifugeId;
    uint32 immutable ETH_EID = ethConfig.adapters.layerZero.layerZeroEid;
    uint32 immutable BASE_EID = baseConfig.adapters.layerZero.layerZeroEid;

    ISpoke immutable spoke = ISpoke(ethConfig.contracts.spoke);
    address immutable ethLzAdapter = ethConfig.contracts.layerZeroAdapter;
    address immutable baseLzAdapter = baseConfig.contracts.layerZeroAdapter;

    bytes packetHeader;
    bytes32 payloadHash;
    bytes32 guid;
    bytes message;
    uint64 packetNonce;

    receive() external payable {}

    function test_sendMessageWithDvnConfig() public {
        // --- Ethereum: send a cross-chain message through the deployed spoke ---
        vm.createSelectFork(ethConfig.network.rpcUrl());

        address testToken = address(new TestToken());

        vm.deal(address(this), 1 ether);
        vm.recordLogs();
        spoke.registerAsset{value: 0.1 ether}(BASE_CENT_ID, testToken, 0, address(this));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory encodedPacket;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PacketSent(bytes,bytes,address)")) {
                (encodedPacket,,) = abi.decode(logs[i].data, (bytes, bytes, address));
                break;
            }
        }
        this.decodePacket(encodedPacket);

        // --- Base: verify DVNs and deliver the message to the deployed adapter ---
        vm.createSelectFork(baseConfig.network.rpcUrl());

        _processPacket();

        vm.expectEmit();
        emit IHubRegistry.NewAsset(newAssetId(ETH_CENT_ID, 1), 8);
        lzEndpoint.lzReceive(
            Origin({srcEid: ETH_EID, sender: ethLzAdapter.toBytes32LeftPadded(), nonce: packetNonce}),
            baseLzAdapter,
            guid,
            message,
            ""
        );
    }

    function decodePacket(bytes calldata packet) external {
        packetNonce = PacketV1Codec.nonce(packet);
        packetHeader = PacketV1Codec.header(packet);
        payloadHash = PacketV1Codec.payloadHash(packet);
        guid = PacketV1Codec.guid(packet);
        message = PacketV1Codec.message(packet);
    }

    function _processPacket() internal {
        IReceiveUln receiveLib = IReceiveUln(lzEndpoint.defaultReceiveLibrary(ETH_EID));
        uint64 confirmations = ethConfig.adapters.layerZero.blockConfirmations;

        address[] memory dvns = baseConfig.adapters.layerZero.dvns;
        for (uint256 i = 0; i < dvns.length; i++) {
            vm.prank(dvns[i]);
            receiveLib.verify(packetHeader, payloadHash, confirmations);
        }

        receiveLib.commitVerification(packetHeader, payloadHash);
    }
}
