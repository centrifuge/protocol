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

    GasService service = new GasService();

    function testGasLimit(bytes calldata message) public view {
        vm.assume(message.length > 0);
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

        uint256 messageGasLimit = service.messageGasLimit(CENTRIFUGE_ID, message);
        assert(messageGasLimit > service.BASE_COST());
        assert(messageGasLimit <= MAX_MESSAGE_COST);
    }
}
