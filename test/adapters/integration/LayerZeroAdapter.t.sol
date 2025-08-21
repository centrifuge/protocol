// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../../src/common/Gateway.sol";
import "../../../src/common/MessageProcessor.sol";
import "../../../src/common/MultiAdapter.sol";
import "../../../src/common/Root.sol";
import "../../../src/common/GasService.sol";
import "../../../src/common/libraries/MessageLib.sol";

import "../../../src/adapters/LayerZeroAdapter.sol";

import "forge-std/Test.sol";

import {LayerZeroV2Helper} from "pigeon/src/layerzero-v2/LayerZeroV2Helper.sol";

contract LayerZeroAdapterPigeonTest is Test {
    using CastLib for *;
    using MessageLib for *;
    using MathLib for *;

    // pigeon lib helper used to mock the relayer
    LayerZeroV2Helper lzHelper;

    address deployer = makeAddr("deployer");
    address delegate = makeAddr("delegate");

    Gateway public arbGateway;
    MultiAdapter public arbMultiAdapter;
    LayerZeroAdapter public arbLzAdapter;

    Gateway public baseGateway;
    MultiAdapter public baseMultiAdapter;
    LayerZeroAdapter public baseLzAdapter;

    address constant LZ_ENDPOINT_V2_ARB = 0x1a44076050125825900e736c501f859c50fE728c;
    uint32 constant ARB_EID = 30110;

    address constant LZ_ENDPOINT_V2_BASE = 0x1a44076050125825900e736c501f859c50fE728c;
    uint32 constant BASE_EID = 30184;

    uint16 constant ARB_CENTRIFUGE_ID = 1000;
    uint16 constant BASE_CENTRIFUGE_ID = 2000;

    string RPC_BASE = vm.envString("RPC_BASE");
    string RPC_ARB = vm.envString("RPC_ARB");

    uint256 ARB_FORK_ID;
    uint256 BASE_FORK_ID;

    // event emitted by LZ endpoint
    event PacketSent(bytes encodedPayload, bytes options, address sendLibrary);
    // events emitted by dest chain centrifuge
    event HandlePayload(uint16 indexed centrifugeId, bytes32 indexed payloadId, bytes payload, IAdapter adapter);
    event ExecuteMessage(uint16 indexed centrifugeId, bytes message);

    function setUp() public {
        vm.startPrank(deployer);

        /////////////// ARB SETUP //////////////////
        ARB_FORK_ID = vm.createSelectFork(RPC_ARB, 370368374);

        Root arbRoot = new Root({_delay: 0, deployer: deployer});
        arbGateway = new Gateway({
            root_: IRoot(address(arbRoot)),
            gasService_: IGasService(new GasService(1_000_000)),
            deployer: deployer
        });

        arbMultiAdapter = new MultiAdapter({
            localCentrifugeId_: ARB_CENTRIFUGE_ID,
            gateway_: IMessageHandler(arbGateway),
            deployer: deployer
        });
        arbMultiAdapter.rely(address(arbGateway));

        arbLzAdapter = new LayerZeroAdapter({
            entrypoint_: IMessageHandler(address(arbMultiAdapter)),
            endpoint_: LZ_ENDPOINT_V2_ARB,
            delegate: delegate,
            deployer: deployer
        });

        // add LZ adapter to multiAdapter
        IAdapter[] memory adaptersOnArb = new IAdapter[](1);
        adaptersOnArb[0] = IAdapter(address(arbLzAdapter));
        arbMultiAdapter.file("adapters", BASE_CENTRIFUGE_ID, adaptersOnArb);

        // add multiAdapter to gateway
        arbGateway.file("adapter", address(arbMultiAdapter));

        // register message processor
        MessageProcessor arbMp = new MessageProcessor({
            root_: IRoot(address(arbRoot)),
            tokenRecoverer_: ITokenRecoverer(address(0)),
            deployer: deployer
        });
        arbMp.rely(address(arbGateway));
        arbGateway.file("processor", address(arbMp));
        arbGateway.rely(address(arbMultiAdapter));

        /////////////// BASE SETUP //////////////////
        BASE_FORK_ID = vm.createSelectFork(RPC_BASE, 34451932);

        Root baseRoot = new Root({_delay: 0, deployer: deployer});
        baseGateway = new Gateway({
            root_: IRoot(address(baseRoot)),
            gasService_: IGasService(new GasService(1_000_000)),
            deployer: deployer
        });
        baseMultiAdapter = new MultiAdapter({
            localCentrifugeId_: BASE_CENTRIFUGE_ID,
            gateway_: IMessageHandler(baseGateway),
            deployer: deployer
        });

        baseLzAdapter = new LayerZeroAdapter({
            entrypoint_: IMessageHandler(address(baseMultiAdapter)),
            endpoint_: LZ_ENDPOINT_V2_BASE,
            delegate: delegate,
            deployer: deployer
        });
        baseMultiAdapter.rely(address(baseGateway));

        // add LZ adapter to multiAdapter
        IAdapter[] memory adaptersOnBase = new IAdapter[](1);
        adaptersOnBase[0] = IAdapter(address(baseLzAdapter));
        baseMultiAdapter.file("adapters", ARB_CENTRIFUGE_ID, adaptersOnBase);

        // add multiAdapter to gateway
        baseGateway.file("adapter", address(baseMultiAdapter));

        // register message processor
        MessageProcessor baseMp = new MessageProcessor({
            root_: IRoot(address(baseRoot)),
            tokenRecoverer_: ITokenRecoverer(address(0)),
            deployer: deployer
        });
        baseMp.rely(address(baseGateway));
        baseGateway.file("processor", address(baseMp));
        baseGateway.rely(address(baseMultiAdapter));
        baseRoot.rely(address(baseMp));

        vm.stopPrank();
    }

    function test_send_from_adapter() public {
        vm.selectFork(ARB_FORK_ID);

        bytes memory payload = "Hello LayerZero";

        // wire base to arb adapter
        vm.prank(deployer);
        arbLzAdapter.wire({centrifugeId: BASE_CENTRIFUGE_ID, layerZeroEid: BASE_EID, adapter: address(baseLzAdapter)});

        // LZ endpoint should emit `PacketSent`
        vm.expectEmit(true, true, true, true);
        emit PacketSent({
            encodedPayload: _getExpectedEncodedPayload(
                ARB_EID, address(arbLzAdapter), BASE_EID, address(baseLzAdapter).toBytes32LeftPadded(), payload
            ),
            options: _getExpectedOptions(200_000),
            sendLibrary: address(0x975bcD720be66659e3EB3C0e4F1866a3020E493A)
        });

        // send msg from arb to base, directly at adapter
        deal(address(arbMultiAdapter), 1 ether);
        uint256 expectedFee =
            arbLzAdapter.estimate({centrifugeId: BASE_CENTRIFUGE_ID, payload: payload, gasLimit: 200_000});
        vm.prank(address(arbMultiAdapter));
        arbLzAdapter.send{value: expectedFee}({
            centrifugeId: BASE_CENTRIFUGE_ID,
            payload: payload,
            gasLimit: 200_000,
            refund: deployer
        });
    }

    function test_send_from_multiAdapter() public {
        vm.selectFork(ARB_FORK_ID);

        bytes memory payload = "Hello LayerZero";

        // wire base to arb adapter
        vm.prank(deployer);
        arbLzAdapter.wire({centrifugeId: BASE_CENTRIFUGE_ID, layerZeroEid: BASE_EID, adapter: address(baseLzAdapter)});

        // LZ endpoint should emit `PacketSent`
        vm.expectEmit(true, true, true, true);
        emit PacketSent({
            encodedPayload: _getExpectedEncodedPayload(
                ARB_EID, address(arbLzAdapter), BASE_EID, address(baseLzAdapter).toBytes32LeftPadded(), payload
            ),
            options: _getExpectedOptions(200_000),
            sendLibrary: address(0x975bcD720be66659e3EB3C0e4F1866a3020E493A)
        });

        // send msg from arb to base, from multiAdapter
        deal(address(arbGateway), 1 ether);
        uint256 expectedFee =
            arbLzAdapter.estimate({centrifugeId: BASE_CENTRIFUGE_ID, payload: payload, gasLimit: 200_000});
        vm.prank(address(arbGateway));
        arbMultiAdapter.send{value: expectedFee}({
            centrifugeId: BASE_CENTRIFUGE_ID,
            payload: payload,
            gasLimit: 200_000,
            refund: deployer
        });
    }

    function test_send_from_gateway() public {
        vm.selectFork(ARB_FORK_ID);

        // wire base to arb adapter
        vm.startPrank(deployer);
        arbLzAdapter.wire({centrifugeId: BASE_CENTRIFUGE_ID, layerZeroEid: BASE_EID, adapter: address(baseLzAdapter)});

        // protocol msg
        bytes memory payload = (MessageLib.NotifyPool({poolId: 7})).serialize();

        // subsidize pool
        deal(deployer, 5 ether);
        uint128 gasLimit = arbGateway.gasService().messageGasLimit(0, payload);
        uint256 expectedFee =
            arbLzAdapter.estimate({centrifugeId: BASE_CENTRIFUGE_ID, payload: payload, gasLimit: gasLimit});
        arbGateway.setRefundAddress({poolId: PoolId.wrap(uint64(7)), refund: IRecoverable(deployer)});
        arbGateway.subsidizePool{value: expectedFee}({poolId: PoolId.wrap(uint64(7))});

        // LZ endpoint should emit `PacketSent`
        vm.expectEmit(true, true, true, true);
        emit PacketSent({
            encodedPayload: _getExpectedEncodedPayload(
                ARB_EID, address(arbLzAdapter), BASE_EID, address(baseLzAdapter).toBytes32LeftPadded(), payload
            ),
            options: _getExpectedOptions(gasLimit),
            sendLibrary: address(0x975bcD720be66659e3EB3C0e4F1866a3020E493A)
        });

        // send msg from arb to base, from gateway
        arbGateway.send({centrifugeId: BASE_CENTRIFUGE_ID, message: payload});
    }

    function test_e2e_send_from_gateway_and_receive_on_dst() public {
        // wire base to arb adapter
        vm.selectFork(ARB_FORK_ID);
        vm.prank(deployer);
        arbLzAdapter.wire({centrifugeId: BASE_CENTRIFUGE_ID, layerZeroEid: BASE_EID, adapter: address(baseLzAdapter)});

        // wire arb to base adapter
        vm.selectFork(BASE_FORK_ID);
        vm.startPrank(deployer);
        baseLzAdapter.wire({centrifugeId: ARB_CENTRIFUGE_ID, layerZeroEid: ARB_EID, adapter: address(arbLzAdapter)});

        vm.selectFork(ARB_FORK_ID);

        // protocol msg
        bytes memory payload = (MessageLib.ScheduleUpgrade({target: bytes32(bytes20(address(4000)))})).serialize();

        // subsidize pool
        deal(deployer, 5 ether);
        uint128 gasLimit = arbGateway.gasService().messageGasLimit(0, payload);
        uint256 expectedFee =
            arbLzAdapter.estimate({centrifugeId: BASE_CENTRIFUGE_ID, payload: payload, gasLimit: gasLimit});
        arbGateway.setRefundAddress({poolId: PoolId.wrap(uint64(0)), refund: IRecoverable(deployer)});
        arbGateway.subsidizePool{value: expectedFee}({poolId: PoolId.wrap(uint64(0))});

        // LZ endpoint should emit `PacketSent`
        vm.expectEmit(true, true, true, true);
        emit PacketSent({
            encodedPayload: _getExpectedEncodedPayload(
                ARB_EID, address(arbLzAdapter), BASE_EID, address(baseLzAdapter).toBytes32LeftPadded(), payload
            ),
            options: _getExpectedOptions(arbGateway.gasService().messageGasLimit(0, payload)),
            sendLibrary: address(0x975bcD720be66659e3EB3C0e4F1866a3020E493A)
        });

        // send msg from arb to base, from gateway. Record logs to enable Pigeon to mock the relayer
        vm.recordLogs();
        arbGateway.send({centrifugeId: BASE_CENTRIFUGE_ID, message: payload});
        vm.stopPrank();

        // expect HandlePayload event on the dst chain to confirm msg is properly delivered
        vm.selectFork(BASE_FORK_ID);
        bytes32 expectedPayloadId =
            keccak256(abi.encodePacked(ARB_CENTRIFUGE_ID, BASE_CENTRIFUGE_ID, keccak256(payload)));
        vm.expectEmit(true, true, true, true);
        emit HandlePayload({
            centrifugeId: ARB_CENTRIFUGE_ID,
            payloadId: expectedPayloadId,
            payload: payload,
            adapter: IAdapter(address(arbLzAdapter))
        });

        // expect ExecuteMessage event on the dst chain to confirm msg is properly delivered
        vm.expectEmit(true, true, true, true);
        emit ExecuteMessage({centrifugeId: ARB_CENTRIFUGE_ID, message: payload});

        // pigeon calls the destination chain target. Call should succeed and emit the expected events
        vm.selectFork(ARB_FORK_ID);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        lzHelper = new LayerZeroV2Helper();
        lzHelper.help(LZ_ENDPOINT_V2_BASE, BASE_FORK_ID, logs);
    }

    ////////////////////// utils /////////////////////

    function _getExpectedEncodedPayload(
        uint32 srcEid,
        address sender,
        uint32 dstEid,
        bytes32 receiver,
        bytes memory message
    ) internal pure returns (bytes memory) {
        bytes32 guid =
            keccak256(abi.encodePacked(uint64(1), srcEid, bytes32(uint256(uint160(sender))), dstEid, receiver));
        Packet memory packet = Packet({
            nonce: 1,
            srcEid: srcEid,
            sender: sender,
            dstEid: dstEid,
            receiver: receiver,
            guid: guid,
            message: message
        });

        bytes memory header = abi.encodePacked(
            uint8(1),
            packet.nonce,
            packet.srcEid,
            bytes32(uint256(uint160(packet.sender))),
            packet.dstEid,
            packet.receiver
        );
        bytes memory payload = abi.encodePacked(packet.guid, packet.message);
        bytes memory encodedPacket = abi.encodePacked(header, payload);

        return encodedPacket;
    }

    function _getExpectedOptions(uint128 gasLimit) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint16(3), uint8(1), abi.encodePacked(gasLimit).length.toUint16() + 1, uint8(1), abi.encodePacked(gasLimit)
        );
    }

    struct Packet {
        uint64 nonce;
        uint32 srcEid;
        address sender;
        uint32 dstEid;
        bytes32 receiver;
        bytes32 guid;
        bytes message;
    }
}