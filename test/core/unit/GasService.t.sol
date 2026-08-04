// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "../../../src/misc/libraries/BytesLib.sol";

import {MessageLib, MessageType, VaultUpdateKind} from "../../../src/core/messaging/libraries/MessageLib.sol";

import {GasService} from "../../../src/admin/GasService.sol";
import {MAX_MESSAGE_COST} from "../../../src/admin/interfaces/IGasService.sol";

import "forge-std/Test.sol";

contract GasServiceTest is Test {
    using MessageLib for *;
    using BytesLib for *;

    uint16 constant CENTRIFUGE_ID = 1;
    GasService service;

    function setUp() public {
        uint8[32] memory txLimits;
        txLimits[0] = 30; // Millions
        txLimits[1] = 150; // Millions
        txLimits[10] = 64; // Millions

        service = new GasService(txLimits, CENTRIFUGE_ID);
    }

    function testDefaultChainUsesDefaultFailureGasReserve() public view {
        assertEq(service.messageFailureGasReserve(), service.DEFAULT_FAILURE_GAS_RESERVE());
    }

    function testMonadChainUsesMonadFailureGasReserve() public {
        uint8[32] memory txLimits;
        txLimits[0] = 30;

        GasService monadService = new GasService(txLimits, service.MONAD_CENTRIFUGE_ID());
        assertEq(monadService.messageFailureGasReserve(), monadService.MONAD_FAILURE_GAS_RESERVE());
        assertTrue(monadService.MONAD_FAILURE_GAS_RESERVE() != monadService.DEFAULT_FAILURE_GAS_RESERVE());
    }

    function testGasLimit(uint256 len, bytes calldata seed) public view {
        len = bound(len, 266, 4096); // ensuring we can deserialize extraGasLimit from any message (NotifyShareClass reads at offset 250)

        bytes memory message = new bytes(len);
        for (uint256 i; i < len && i < seed.length; ++i) {
            message[i] = seed[i];
        }

        vm.assume(message.messageExtraGasLimit() < 100_000);
        vm.assume(message.messageCode() > 0);
        vm.assume(message.messageCode() <= uint8(type(MessageType).max));

        if (message.messageCode() == uint8(MessageType.UpdateVault)) {
            vm.assume(message.length > 73);
            uint8 vaultKind = message.toUint8(73);
            vm.assume(vaultKind >= 0);
            vm.assume(vaultKind <= uint8(type(VaultUpdateKind).max));
        }

        if (message.messageCode() == uint8(MessageType.ManagerCallFromSpoke)) {
            vm.assume(message.length >= 91); // Minimum length without payload
        }

        uint256 messageGasLimit = service.messageOverallGasLimit(CENTRIFUGE_ID, message);
        assert(messageGasLimit > service.BASE_ADAPTER_COST());
        assertLt(messageGasLimit, MAX_MESSAGE_COST, "Higher than MAX_MESSAGE_COST");
    }

    function testAllMessageTypesHaveSufficientGasReserve() public view {
        // 266 bytes covers the deepest offset read by messageExtraGasLimit across all types (NotifyShareClass
        // reads its extraGasLimit at offset 250 + 16 bytes). Extra-gas fields are zero-filled, giving the floor
        // for messageProcessingGasLimit — if the floor satisfies the invariant, any message with non-zero
        // extra gas also satisfies it.
        bytes memory message = new bytes(266);
        uint8 maxType = uint8(type(MessageType).max);

        for (uint8 i = 1; i <= maxType; i++) {
            message[0] = bytes1(i);

            if (MessageType(i) == MessageType.UpdateVault) {
                // UpdateVault dispatches on VaultUpdateKind, producing different base gas values per sub-kind
                for (uint8 k = 0; k <= uint8(type(VaultUpdateKind).max); k++) {
                    message[73] = bytes1(k); // VaultUpdateKind is encoded at offset 73
                    assertGe(
                        service.messageProcessingGasLimit(CENTRIFUGE_ID, message),
                        service.messageFailureGasReserve(),
                        string.concat(
                            "UpdateVault kind ",
                            vm.toString(k),
                            ": messageProcessingGasLimit does not cover messageFailureGasReserve"
                        )
                    );
                }
                message[73] = 0;
            } else {
                assertGe(
                    service.messageProcessingGasLimit(CENTRIFUGE_ID, message),
                    service.messageFailureGasReserve(),
                    string.concat(
                        "type ", vm.toString(i), ": messageProcessingGasLimit does not cover messageFailureGasReserve"
                    )
                );
            }
        }
    }

    function testMessageLength() public view {
        bytes memory message = MessageLib.NotifyPool({poolId: 1}).serialize();
        assertEq(service.messageLength(message), message.messageLength());
    }

    function testMessagePoolId() public view {
        bytes memory message = MessageLib.NotifyPool({poolId: 1}).serialize();
        assertEq(service.messagePoolId(message).raw(), message.messagePoolId().raw());
    }

    function testRoutePoolId() public view {
        bytes memory message = MessageLib.SetPoolAdapters({
                poolId: 1, threshold: 1, targetSessionId: 1, adapterList: new bytes32[](0)
            }).serialize();

        assertEq(service.routePoolId(message, true).raw(), message.messagePoolId().raw());
        assertEq(service.routePoolId(message, false).raw(), 0);
    }

    function testMessageSourceCentrifugeId() public view {
        bytes memory message = MessageLib.NotifyPool({poolId: uint64(CENTRIFUGE_ID) << 48}).serialize();
        assertEq(service.messageSourceCentrifugeId(message), message.messageSourceCentrifugeId());
    }

    function _updateVault(VaultUpdateKind kind, bytes memory payload) internal pure returns (bytes memory) {
        return MessageLib.UpdateVault({
                poolId: 1,
                scId: bytes16(uint128(2)),
                assetId: 3,
                vaultOrFactory: bytes32(uint256(4)),
                kind: uint8(kind),
                extraGasLimit: 0,
                payload: payload
            }).serialize();
    }

    function testMessageProcessingGasLimitIgnoresPayloadForLinkAndUnlink() public view {
        VaultUpdateKind[2] memory kinds = [VaultUpdateKind.Link, VaultUpdateKind.Unlink];

        for (uint256 i; i < kinds.length; i++) {
            assertEq(
                service.messageProcessingGasLimit(CENTRIFUGE_ID, _updateVault(kinds[i], "")),
                service.messageProcessingGasLimit(CENTRIFUGE_ID, _updateVault(kinds[i], new bytes(900))),
                string.concat("kind ", vm.toString(uint8(kinds[i])), ": limit depends on an unread payload")
            );
        }
    }

    /// @dev The gas estimator fully deserializes UpdateVault to read the kind byte.
    function testMessageProcessingGasLimitRevertsOnOverlongDeclaredPayload() public {
        bytes memory message = _updateVault(VaultUpdateKind.Link, "");
        assertEq(message.length, 92);

        uint16 declared = 300;
        message[90] = bytes1(uint8(declared >> 8));
        message[91] = bytes1(uint8(declared));

        vm.expectRevert(BytesLib.SliceOutOfBounds.selector);
        service.messageProcessingGasLimit(CENTRIFUGE_ID, message);
    }

    function testMaxBatchGasLimit(uint16 centrifugeId) public view {
        uint256 expectedGasLimit = service.DEFAULT_SUPPORTED_TX_LIMIT();
        if (centrifugeId == 0) expectedGasLimit = 30;
        if (centrifugeId == 1) expectedGasLimit = 150;
        if (centrifugeId == 10) expectedGasLimit = 64;
        expectedGasLimit = expectedGasLimit * 1_000_000;

        uint256 maxBatchGasLimit = service.maxBatchGasLimit(centrifugeId);
        assertEq(maxBatchGasLimit, expectedGasLimit);
    }
}
