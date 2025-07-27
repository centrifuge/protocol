// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "../../../src/misc/libraries/BytesLib.sol";

import {GasService} from "../../../src/common/GasService.sol";
import {MAX_MESSAGE_COST} from "../../../src/common/interfaces/IGasService.sol";
import {MessageLib, MessageType, VaultUpdateKind} from "../../../src/common/libraries/MessageLib.sol";

import "forge-std/Test.sol";

contract GasServiceTest is Test {
    using MessageLib for *;
    using BytesLib for *;

    uint128 constant MAX_BATCH_GAS_LIMIT = 25_000_000; // 25M gas units
    uint16 constant CENTRIFUGE_ID = 1;

    GasService service = new GasService(MAX_BATCH_GAS_LIMIT);

    function testGasLimit(bytes calldata message) public view {
        vm.assume(message.length > 0);
        vm.assume(message.messageCode() > 0);
        vm.assume(
            message.messageCode() < uint8(MessageType._Placeholder5)
                || message.messageCode() > uint8(MessageType._Placeholder15)
        );
        vm.assume(message.messageCode() <= uint8(type(MessageType).max));

        if (message.messageCode() == uint8(MessageType.UpdateVault)) {
            vm.assume(message.length > 73);
            uint8 vaultKind = message.toUint8(73);
            vm.assume(vaultKind >= 0);
            vm.assume(vaultKind <= uint8(type(VaultUpdateKind).max));
        }

        uint256 messageGasLimit = service.messageGasLimit(CENTRIFUGE_ID, message);
        assert(messageGasLimit > service.BASE_COST());
        assert(messageGasLimit <= MAX_MESSAGE_COST);
    }

    function testMaxGasLimit(bytes calldata) public view {
        uint256 maxBatchGasLimit = service.maxBatchGasLimit(CENTRIFUGE_ID);
        assertEq(maxBatchGasLimit, MAX_BATCH_GAS_LIMIT);
    }
}
