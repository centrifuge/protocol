// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IMessageProperties} from "src/common/interfaces/IMessageProperties.sol";
import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {GasService, IGasService} from "src/common/GasService.sol";

contract GasServiceTest is Test {
    using MessageLib for *;

    uint128 constant MESSAGE_GAS_LIMIT = 0.04 ether;
    uint128 constant MAX_BATCH_SIZE = 10_000_000 ether;
    uint16 constant CENTRIFUGE_ID = 1;

    GasService service = new GasService(MAX_BATCH_SIZE, MESSAGE_GAS_LIMIT);

    function testGasLimit(bytes calldata message) public view {
        uint256 messageGasLimit = service.gasLimit(CENTRIFUGE_ID, message);
        assertEq(messageGasLimit, MESSAGE_GAS_LIMIT);
    }

    function testMaxBatchSize(bytes calldata) public view {
        uint256 maxBatchSize = service.maxBatchSize(CENTRIFUGE_ID);
        assertEq(maxBatchSize, MAX_BATCH_SIZE);
    }
}
