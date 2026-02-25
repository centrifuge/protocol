// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "../../../src/misc/libraries/BytesLib.sol";

import {GasService} from "../../../src/core/messaging/GasService.sol";
import {MAX_MESSAGE_COST} from "../../../src/core/messaging/interfaces/IGasService.sol";
import {MessageLib, MessageType, VaultUpdateKind} from "../../../src/core/messaging/libraries/MessageLib.sol";

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

        service = new GasService(txLimits);
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
        assert(messageGasLimit > service.BASE_COST());
        assertLt(messageGasLimit, MAX_MESSAGE_COST, "Higher than MAX_MESSAGE_COST");
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
