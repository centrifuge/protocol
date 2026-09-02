// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {PoolEscrow} from "../../../../src/core/spoke/PoolEscrow.sol";
import {PoolEscrowFactory} from "../../../../src/core/spoke/factories/PoolEscrowFactory.sol";
import {IPoolEscrowFactory} from "../../../../src/core/spoke/factories/interfaces/IPoolEscrowFactory.sol";

import "forge-std/Test.sol";

contract PoolEscrowFactoryTest is Test {
    PoolEscrowFactory factory;

    address deployer = address(this);
    address root = makeAddr("root");
    address spoke = makeAddr("spoke");
    address randomUser = makeAddr("randomUser");

    function setUp() public {
        factory = new PoolEscrowFactory(root, deployer);
        factory.file("spoke", spoke);
    }

    function testDeployEscrowAtDeterministicAddress(PoolId poolId) public {
        address expectedEscrow = address(factory.escrow(poolId));
        address actual = address(factory.newEscrow(poolId));

        assertEq(expectedEscrow, actual, "Escrow address mismatch");
    }

    function testPoolIdReverseMapping(PoolId poolId) public {
        vm.assume(!poolId.isNull());
        address escrowAddr = address(factory.newEscrow(poolId));
        assertEq(factory.poolId(escrowAddr).raw(), poolId.raw(), "Reverse pool id mismatch");
        assertFalse(factory.poolId(escrowAddr).isNull(), "Deployed escrow must not read as unknown");
    }

    function testPoolIdReturnsNullForUnknownAddress(PoolId poolId, address unknown) public {
        vm.assume(!poolId.isNull());
        address escrowAddr = address(factory.newEscrow(poolId));
        vm.assume(unknown != escrowAddr);
        assertTrue(factory.poolId(unknown).isNull(), "Unknown address should return null pool id");
    }

    function testDeployEscrowTwiceReverts(PoolId poolId) public {
        factory.newEscrow(poolId);
        vm.expectRevert();
        factory.newEscrow(poolId);
    }

    function testEscrowHasCorrectPermissions(PoolId poolId, address nonWard) public {
        vm.assume(nonWard != root && nonWard != spoke);
        address escrowAddr = address(factory.newEscrow(poolId));

        PoolEscrow escrow = PoolEscrow(payable(escrowAddr));

        assertEq(escrow.wards(root), 1, "root not authorized");
        assertEq(escrow.wards(spoke), 1, "spoke not authorized");

        assertEq(escrow.wards(address(factory)), 0, "factory still authorized");
        assertEq(escrow.wards(nonWard), 0, "unexpected authorization");
    }

    function testFileSetsSpoke() public {
        factory.file("spoke", randomUser);
        assertEq(factory.spoke(), randomUser);
    }

    function testFileWithUnknownParamReverts() public {
        vm.expectRevert(IPoolEscrowFactory.FileUnrecognizedParam.selector);
        factory.file("unknown", randomUser);
    }

    function testFileUnauthorizedReverts() public {
        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        factory.file("spoke", randomUser);
    }
}
