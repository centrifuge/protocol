// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";

import {IRefundEscrow} from "../../../src/vaults/interfaces/IRefundEscrow.sol";
import {RefundEscrowFactory, IRefundEscrowFactory} from "../../../src/vaults/factories/RefundEscrowFactory.sol";

import "forge-std/Test.sol";

contract RefundEscrowFactoryTest is Test {
    address immutable ANY = makeAddr("any");
    address immutable AUTH = makeAddr("auth");
    address immutable CONTROLLER = makeAddr("receiver");
    address immutable ROOT = makeAddr("root");

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
        factory.file("root", ROOT);

        vm.prank(AUTH);
        IRefundEscrow escrow = factory.newEscrow(POOL_A);

        assertEq(address(escrow), address(factory.get(POOL_A)));
        assertEq(IAuth(address(escrow)).wards(CONTROLLER), 1, "Controller should have ward");
        assertEq(IAuth(address(escrow)).wards(ROOT), 1, "Root should have ward");
        assertEq(IAuth(address(escrow)).wards(address(factory)), 0, "Factory should not have ward");
    }

    function testCannotDeployTwiceForSamePool() external {
        vm.prank(AUTH);
        factory.file("controller", CONTROLLER);

        vm.prank(AUTH);
        factory.newEscrow(POOL_A);

        // Second deployment should revert (CREATE2 constraint)
        vm.prank(AUTH);
        vm.expectRevert();
        factory.newEscrow(POOL_A);
    }
}

contract RefundEscrowFactoryTestControllerMigration is RefundEscrowFactoryTest {
    function testControllerMigrationMaintainsAddresses() external {
        address controller1 = makeAddr("controller1");
        address controller2 = makeAddr("controller2");

        vm.prank(AUTH);
        factory.file("controller", controller1);

        vm.prank(AUTH);
        IRefundEscrow escrow = factory.newEscrow(POOL_A);
        address escrowAddress = address(escrow);
        assertEq(IAuth(address(escrow)).wards(controller1), 1);

        vm.prank(AUTH);
        factory.file("controller", controller2);
        assertEq(address(factory.get(POOL_A)), escrowAddress, "Address changed after controller migration");
    }
}
