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

    uint64 constant MESSAGE_COST = 40000000000000000;
    uint64 constant PROOF_COST = 20000000000000000;
    uint128 constant GAS_PRICE = 2500000000000000000;
    uint256 constant TOKEN_PRICE = 178947400000000;
    uint32 constant CHAIN_ID = 1;

    GasService service;

    function setUp() public {
        service = new GasService(MESSAGE_COST, PROOF_COST, GAS_PRICE, TOKEN_PRICE);
    }

    function testDeployment() public {
        service = new GasService(MESSAGE_COST, PROOF_COST, GAS_PRICE, TOKEN_PRICE);
        assertEq(service.wards(address(this)), 1);
        assertEq(service.messageCost(), MESSAGE_COST);
        assertEq(service.proofCost(), PROOF_COST);
        assertEq(service.gasPrice(), GAS_PRICE);
        assertEq(service.tokenPrice(), TOKEN_PRICE);
        assertEq(service.lastUpdatedAt(), block.timestamp);
    }

    function testFilings(uint64 messageCost, uint64 proofCost, bytes32 what) public {
        vm.assume(what != "messageCost");
        vm.assume(what != "proofCost");

        service.file("messageCost", messageCost);
        service.file("proofCost", proofCost);
        assertEq(service.messageCost(), messageCost);
        assertEq(service.proofCost(), proofCost);

        vm.expectRevert(IGasService.FileUnrecognizedParam.selector);
        service.file(what, messageCost);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        service.file("messageCost", messageCost);
    }

    function testUpdateGasPrice(uint128 value) public {
        vm.assume(value != 0);
        vm.assume(value != GAS_PRICE);

        uint64 pastDate = uint64(service.lastUpdatedAt() - 1);
        uint64 futureDate = uint64(service.lastUpdatedAt() + 1);

        uint64 lastUpdateAt = uint64(service.lastUpdatedAt());

        vm.expectRevert(IGasService.PriceCannotBeZero.selector);
        service.updateGasPrice(0, futureDate);
        assertEq(lastUpdateAt, service.lastUpdatedAt());

        vm.expectRevert(IGasService.AlreadySetPrice.selector);
        service.updateGasPrice(GAS_PRICE, futureDate);
        assertEq(lastUpdateAt, service.lastUpdatedAt());

        vm.expectRevert(IGasService.OutdatedPrice.selector);
        service.updateGasPrice(value, pastDate);
        assertEq(service.gasPrice(), GAS_PRICE);

        service.updateGasPrice(value, futureDate);
        assertEq(service.gasPrice(), value);
        assertEq(service.lastUpdatedAt(), futureDate);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        service.updateGasPrice(value, futureDate);
    }

    function testUpdateTokenPrice(uint256 value) public {
        service.updateTokenPrice(value);
        assertEq(service.tokenPrice(), value);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        service.updateTokenPrice(value);
    }

    function testEstimateFunction(bytes calldata message) public view {
        vm.assume(message.length > 1);
        vm.assume(message.toUint8(0) != uint8(MessageType.MessageProof) && message.toUint8(0) <= 28);
        bytes memory proof = MessageLib.MessageProof(keccak256(message)).serialize();

        uint256 messageCost = service.estimate(CHAIN_ID, message);
        uint256 proofCost = service.estimate(CHAIN_ID, proof);

        assertEq(messageCost, 17894740000000);
        assertEq(proofCost, 8947370000000);
    }
}
