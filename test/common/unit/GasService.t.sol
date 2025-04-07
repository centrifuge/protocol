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
    uint64 constant PROOF_GAS_LIMIT = 20000000000000000;
    uint16 constant CHAIN_ID = 1;

    GasService service;

    function setUp() public {
        service = new GasService(MESSAGE_GAS_LIMIT, PROOF_GAS_LIMIT);
    }

    function testDeployment() public {
        service = new GasService(MESSAGE_GAS_LIMIT, PROOF_GAS_LIMIT);
        assertEq(service.messageGasLimit(), MESSAGE_GAS_LIMIT);
        assertEq(service.proofGasLimit(), PROOF_GAS_LIMIT);
    }

    function testGasLimit(bytes calldata message) public view {
        vm.assume(message.length > 1);
        vm.assume(message.messageCode() != uint8(MessageType.MessageProof));
        bytes memory proof = MessageLib.MessageProof(keccak256(message)).serialize();

        uint256 messageGasLimit = service.gasLimit(CHAIN_ID, message);
        assertEq(messageGasLimit, MESSAGE_GAS_LIMIT);

        uint256 proofGasLimit = service.gasLimit(CHAIN_ID, proof);
        assertEq(proofGasLimit, PROOF_GAS_LIMIT);
    }
}
