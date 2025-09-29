// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {IRefundEscrow} from "../../../src/vaults/interfaces/IRefundEscrow.sol";
import {RefundEscrowFactory, IRefundEscrowFactory} from "../../../src/vaults/factories/RefundEscrowFactory.sol";

import "forge-std/Test.sol";

contract RefundEscrowFactoryTest is Test {
    address immutable ANY = makeAddr("any");
    address immutable AUTH = makeAddr("auth");
    address immutable CONTROLLER = makeAddr("receiver");

    PoolId constant POOL_A = PoolId.wrap(1);

    RefundEscrowFactory factory = new RefundEscrowFactory(AUTH);
}

contract RefundEscrowFactoryTestFile is RefundEscrowFactoryTest {
    function testErrNotAuthorized() external {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        factory.file("controller", address(123));
    }

    function testErrFileUnrecognizedParam() external {
        vm.prank(AUTH);
        vm.expectRevert(IRefundEscrowFactory.FileUnrecognizedParam.selector);
        factory.file("unknown", address(123));
    }

    function testFile() external {
        vm.prank(AUTH);
        factory.file("controller", address(123));

        assertEq(factory.controller(), address(123));
    }
}

contract RefundEscrowFactoryTestNewEscrow is RefundEscrowFactoryTest {
    function testErrNotAuthorized() external {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        factory.newEscrow(POOL_A);
    }

    function testNewEscrow() external {
        vm.prank(AUTH);
        factory.file("controller", CONTROLLER);

        vm.prank(AUTH);
        IRefundEscrow escrow = factory.newEscrow(POOL_A);

        assertEq(address(escrow), address(factory.get(POOL_A)));
        assertEq(IAuth(address(escrow)).wards(CONTROLLER), 1);
    }
}

