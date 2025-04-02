// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {GasService, IGasService} from "src/common/GasService.sol";

contract GasServiceTest is Test {
    using MessageLib for *;
    using BytesLib for bytes;

    uint64 constant MESSAGE_GAS_LIMIT = 40000000000000000;
    uint64 constant PROOF_GAS_LIMIT = 20000000000000000;
    uint16 constant CHAIN_ID = 1;

    GasService service;

    function setUp() public {
        service = new GasService(MESSAGE_GAS_LIMIT, PROOF_GAS_LIMIT);
    }

    function testDeployment() public {
        service = new GasService(MESSAGE_GAS_LIMIT, PROOF_GAS_LIMIT);
        assertEq(service.wards(address(this)), 1);
        assertEq(service.messageGasLimit(), MESSAGE_GAS_LIMIT);
        assertEq(service.proofGasLimit(), PROOF_GAS_LIMIT);
    }

    function testFilings(uint64 messageGasLimit, uint64 proofGasLimit, bytes32 what) public {
        vm.assume(what != "messageGasLimit");
        vm.assume(what != "proofGasLimit");

        service.file("messageGasLimit", messageGasLimit);
        service.file("proofGasLimit", proofGasLimit);
        assertEq(service.messageGasLimit(), messageGasLimit);
        assertEq(service.proofGasLimit(), proofGasLimit);

        vm.expectRevert(IGasService.FileUnrecognizedParam.selector);
        service.file(what, messageGasLimit);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        service.file("messageGasLimit", messageGasLimit);
    }

    function testEstimateFunction(bytes calldata message) public view {
        vm.assume(message.length > 1);
        vm.assume(message.toUint8(0) != uint8(MessageType.MessageProof) && message.toUint8(0) <= 28);
        bytes memory proof = MessageLib.MessageProof(keccak256(message)).serialize();

        uint256 messageGasLimit = service.estimate(CHAIN_ID, message);
        uint256 proofGasLimit = service.estimate(CHAIN_ID, proof);

        assertEq(messageGasLimit, MESSAGE_GAS_LIMIT);
        assertEq(proofGasLimit, PROOF_GAS_LIMIT);
    }
}
