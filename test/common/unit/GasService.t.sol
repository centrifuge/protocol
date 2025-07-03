// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GasService} from "src/common/GasService.sol";
import {MAX_MESSAGE_COST} from "src/common/interfaces/IGasService.sol";
import {MessageLib, MessageType} from "src/common/libraries/MessageLib.sol";

import "forge-std/Test.sol";

contract GasServiceTest is Test {
    using MessageLib for *;

    uint128 constant MESSAGE_GAS_LIMIT = MAX_MESSAGE_COST;
    uint128 constant BATCH_GAS_LIMIT = 10_000_000 ether;
    uint16 constant CENTRIFUGE_ID = 1;

    GasService service = new GasService(BATCH_GAS_LIMIT, MESSAGE_GAS_LIMIT);

    function testGasLimit(bytes calldata message) public view {
        vm.assume(message.length > 0);
        vm.assume(message.messageCode() > 0);
        vm.assume(
            message.messageCode() < uint8(MessageType._Placeholder5)
                || message.messageCode() > uint8(MessageType._Placeholder15)
        );
        vm.assume(message.messageCode() < uint8(type(MessageType).max));

        uint256 messageGasLimit = service.messageGasLimit(CENTRIFUGE_ID, message);
        assert(messageGasLimit > service.BASE_COST());
        assert(messageGasLimit <= MAX_MESSAGE_COST);
    }

    function testBatchGasLimit(bytes calldata) public view {
        uint256 batchGasLimit = service.batchGasLimit(CENTRIFUGE_ID);
        assertEq(batchGasLimit, BATCH_GAS_LIMIT);
    }
}
