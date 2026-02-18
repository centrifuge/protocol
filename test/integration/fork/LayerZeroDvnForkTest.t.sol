// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "../../../src/misc/ERC20.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {newAssetId} from "../../../src/core/types/AssetId.sol";
import {IHubRegistry} from "../../../src/core/hub/interfaces/IHubRegistry.sol";

import {ISafe} from "../../../src/admin/interfaces/ISafe.sol";

import {
    DeployerInput,
    NonCoreReport,
    FullDeployer,
    AdaptersInput,
    WormholeInput,
    AxelarInput,
    LayerZeroInput,
    ChainlinkInput,
    AdapterConnections,
    defaultTxLimits
} from "../../../script/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {Env, EnvConfig} from "../../../script/utils/EnvConfig.s.sol";
import {Origin} from "../../../src/adapters/interfaces/ILayerZeroAdapter.sol";
import {
    SetConfigParam,
    UlnConfig,
    ILayerZeroEndpointV2Like
} from "../../../src/deployment/interfaces/ILayerZeroEndpointV2Like.sol";

library PacketV1Codec {
    uint256 private constant GUID_OFFSET = 81;
    uint256 private constant MESSAGE_OFFSET = 113;

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
/// @notice Deploy on ETH and BASE with DVN config and send a message end to end
contract LayerZeroDvnForkTest is Test, FullDeployer {
    using CastLib for *;

    uint32 constant ULN_CONFIG_TYPE = 2;

    EnvConfig ethConfig = Env.load("ethereum");
    EnvConfig baseConfig = Env.load("base");

    ILayerZeroEndpointV2Ext immutable lzEndpoint = ILayerZeroEndpointV2Ext(ethConfig.adapters.layerZero.endpoint);
    uint16 immutable ETH_CENT_ID = ethConfig.network.centrifugeId;
    uint16 immutable BASE_CENT_ID = baseConfig.network.centrifugeId;
    uint32 immutable ETH_EID = ethConfig.adapters.layerZero.layerZeroEid;
    uint32 immutable BASE_EID = baseConfig.adapters.layerZero.layerZeroEid;

    ISafe immutable protocolSafe = ISafe(ethConfig.network.protocolAdmin);
    ISafe immutable opsSafe = ISafe(ethConfig.network.opsAdmin);

    address testToken;
    address lzAdapter;

    bytes packetHeader;
    bytes32 payloadHash;
    bytes32 guid;
    bytes message;

    receive() external payable {}

    function test_sendMessageWithDvnConfig() public {
        // Deploy on Ethereum and send message
        vm.createSelectFork(ethConfig.network.rpcUrl());

        testToken = address(new TestToken());

        _deployEthereum();
        lzAdapter = address(layerZeroAdapter);

        NonCoreReport memory report = nonCoreReport();

        // Record logs to capture PacketSent event
        vm.recordLogs();
        report.core.spoke.registerAsset{value: 0.1 ether}(BASE_CENT_ID, testToken, 0, address(this));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory encodedPacket;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PacketSent(bytes,bytes,address)")) {
                (encodedPacket,,) = abi.decode(logs[i].data, (bytes, bytes, address));
                break;
            }
        }
        this.decodePacket(encodedPacket);

        // Deploy on Base and receive the message
        vm.createSelectFork(baseConfig.network.rpcUrl());

        _deployBase();

        _processPacket();

        vm.expectEmit();
        emit IHubRegistry.NewAsset(newAssetId(ETH_CENT_ID, 1), 8);
        lzEndpoint.lzReceive(
            Origin({srcEid: ETH_EID, sender: lzAdapter.toBytes32LeftPadded(), nonce: 1}), lzAdapter, guid, message, ""
        );
    }

    function decodePacket(bytes calldata packet) external {
        packetHeader = PacketV1Codec.header(packet);
        payloadHash = PacketV1Codec.payloadHash(packet);
        guid = PacketV1Codec.guid(packet);
        message = PacketV1Codec.message(packet);
    }

    function _deployEthereum() internal {
        deployFull(_fullInput(ETH_CENT_ID, BASE_CENT_ID, BASE_EID, ethConfig.adapters.layerZero.dvns), address(this));
    }

    function _deployBase() internal {
        deployFull(_fullInput(BASE_CENT_ID, ETH_CENT_ID, ETH_EID, baseConfig.adapters.layerZero.dvns), address(this));

        vm.prank(address(protocolGuardian));
        layerZeroAdapter.wire(ETH_CENT_ID, abi.encode(ETH_EID, lzAdapter));
    }

    function _fullInput(uint16 localId, uint16 remoteId, uint32 remoteEid, address[] memory dvns)
        internal
        view
        returns (DeployerInput memory)
    {
        AdapterConnections[] memory connections = new AdapterConnections[](1);
        connections[0] = AdapterConnections({
            centrifugeId: remoteId, layerZeroId: remoteEid, wormholeId: 0, axelarId: "", chainlinkId: 0, threshold: 1
        });

        return DeployerInput({
            centrifugeId: localId,
            version: bytes32("1337"),
            txLimits: defaultTxLimits(),
            protocolSafe: protocolSafe,
            opsSafe: opsSafe,
            adapters: AdaptersInput({
                wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
                axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
                layerZero: LayerZeroInput({
                    shouldDeploy: true,
                    endpoint: address(lzEndpoint),
                    delegate: address(protocolSafe),
                    configParams: _ulnConfig(dvns, remoteEid)
                }),
                chainlink: ChainlinkInput({shouldDeploy: false, ccipRouter: address(0)}),
                connections: connections
            })
        });
    }

    function _ulnConfig(address[] memory dvns, uint32 destEid) internal view returns (SetConfigParam[] memory) {
        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({
            eid: destEid,
            configType: ULN_CONFIG_TYPE,
            config: abi.encode(
                UlnConfig({
                    confirmations: ethConfig.adapters.layerZero.blockConfirmations,
                    requiredDVNCount: uint8(dvns.length),
                    optionalDVNCount: 0,
                    optionalDVNThreshold: 0,
                    requiredDVNs: dvns,
                    optionalDVNs: new address[](0)
                })
            )
        });
        return params;
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
