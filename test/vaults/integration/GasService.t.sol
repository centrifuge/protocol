// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "test/BaseTest.sol";

contract GasServiceTest is BaseTest {
    function testHandleInvalidMessage() public {
        vm.expectRevert(bytes("GasService/invalid-message"));
        gasService.handle(abi.encodePacked(uint8(MessagesLib.Call.Invalid)));
    }

    function testUpdateGasPrice(uint128 price) public {
        price = uint128(bound(price, 1, type(uint128).max));
        vm.assume(price != gasService.gasPrice());

        gateway.file("gasService", address(gasService));

        assertEq(gasService.lastUpdatedAt(), block.timestamp);

        vm.warp(block.timestamp + 1 days);

        centrifugeChain.updateCentrifugeGasPrice(price, uint64(block.timestamp + 1 days));
        assertEq(gasService.gasPrice(), price);
        assertEq(gasService.lastUpdatedAt(), block.timestamp + 1 days);
    }
}
