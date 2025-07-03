// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GasService} from "src/common/GasService.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";

import "forge-std/Test.sol";

contract GasServiceTest is Test {
    using MessageLib for *;

    uint128 constant MESSAGE_GAS_LIMIT = 0.04 ether;
    uint128 constant MAX_BATCH_SIZE = 10_000_000 ether;
    uint16 constant CENTRIFUGE_ID = 1;

    GasService service = new GasService(MAX_BATCH_SIZE, MESSAGE_GAS_LIMIT);

    function testGasLimit(bytes calldata message) public view {
        uint256 messageGasLimit = service.messageGasLimit(CENTRIFUGE_ID, message);
        assertEq(messageGasLimit, MESSAGE_GAS_LIMIT);
    }

    function testBatchGasLimit(bytes calldata) public view {
        uint256 batchGasLimit = service.batchGasLimit(CENTRIFUGE_ID);
        assertEq(batchGasLimit, MAX_BATCH_SIZE);
    }
}
