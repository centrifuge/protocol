// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IMessageProperties} from "src/common/interfaces/IMessageProperties.sol";
import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {GasService, IGasService} from "src/common/GasService.sol";

contract GasServiceTest is Test {
    using MessageLib for *;

    uint64 constant MESSAGE_GAS_LIMIT = 40000000000000000;
    uint16 constant CENTRIFUGE_ID = 1;

    GasService service = new GasService(MESSAGE_GAS_LIMIT);

    function testDeployment() public {
        service = new GasService(MESSAGE_GAS_LIMIT);
        assertEq(service.messageGasLimit(), MESSAGE_GAS_LIMIT);
    }

    function testGasLimit(bytes calldata message) public view {
        uint256 messageGasLimit = service.gasLimit(CENTRIFUGE_ID, message);
        assertEq(messageGasLimit, MESSAGE_GAS_LIMIT);
    }
}
