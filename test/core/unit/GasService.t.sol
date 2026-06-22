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

    function testGasLimit(uint256 len, bytes calldata seed) public view {
        len = bound(len, 121, 4096); // ensuring we can deserialize extraGasLimit from any message

        bytes memory message = new bytes(len);
        for (uint256 i; i < len && i < seed.length; ++i) {
            message[i] = seed[i];
        }

        vm.assume(message.messageExtraGasLimit() < 100_000);
        vm.assume(message.messageCode() > 0);
        vm.assume(message.messageCode() <= uint8(type(MessageType).max));
        // _GAP is a reserved enum gap with no valid message; it reverts with InvalidMessageType()
        vm.assume(message.messageCode() != uint8(MessageType._GAP));

        if (message.messageCode() == uint8(MessageType.UpdateVault)) {
            vm.assume(message.length > 73);
            uint8 vaultKind = message.toUint8(73);
            vm.assume(vaultKind >= 0);
            vm.assume(vaultKind <= uint8(type(VaultUpdateKind).max));
        }

        if (message.messageCode() == uint8(MessageType.UntrustedContractUpdate)) {
            vm.assume(message.length >= 91); // Minimum length without payload
        }

        uint256 messageGasLimit = service.messageOverallGasLimit(CENTRIFUGE_ID, message);
        assert(messageGasLimit > service.BASE_ADAPTER_COST());
        assertLt(messageGasLimit, MAX_MESSAGE_COST, "Higher than MAX_MESSAGE_COST");
    }

    function testAllMessageTypesHaveSufficientGasReserve() public view {
        // 200 bytes covers the deepest offset read by messageExtraGasLimit across all types (offset 91 + 16 bytes).
        // Extra-gas fields are zero-filled, giving the floor for messageProcessingGasLimit — if the floor
        // satisfies the invariant, any message with non-zero extra gas also satisfies it.
        bytes memory message = new bytes(200);
        uint8 maxType = uint8(type(MessageType).max);

        for (uint8 i = 1; i <= maxType; i++) {
            // _GAP is a reserved enum gap with no valid message; it reverts with InvalidMessageType()
            if (MessageType(i) == MessageType._GAP) continue;

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
