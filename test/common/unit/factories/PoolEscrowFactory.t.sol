// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../src/common/types/PoolId.sol";
import {PoolEscrow} from "../../../../src/common/PoolEscrow.sol";
import {PoolEscrowFactory} from "../../../../src/common/factories/PoolEscrowFactory.sol";
import {IPoolEscrowFactory} from "../../../../src/common/factories/interfaces/IPoolEscrowFactory.sol";

import "forge-std/Test.sol";

contract PoolEscrowFactoryTest is Test {
    PoolEscrowFactory factory;

    address deployer = address(this);
    address root = makeAddr("root");
    address gateway = makeAddr("gateway");
    address balanceSheet = makeAddr("balanceSheet");
    address randomUser = makeAddr("randomUser");

    function setUp() public {
        factory = new PoolEscrowFactory(root, deployer);
        factory.file("gateway", gateway);
        factory.file("balanceSheet", balanceSheet);
    }

    function testDeployEscrowAtDeterministicAddress(PoolId poolId) public {
        address expectedEscrow = address(factory.escrow(poolId));
        address actual = address(factory.newEscrow(poolId));

        assertEq(expectedEscrow, actual, "Escrow address mismatch");
    }

    function testDeployEscrowTwiceReverts(PoolId poolId) public {
        factory.newEscrow(poolId);
        vm.expectRevert();
        factory.newEscrow(poolId);
    }

    function testEscrowHasCorrectPermissions(PoolId poolId, address nonWard) public {
        vm.assume(nonWard != root && nonWard != gateway && nonWard != balanceSheet);
        address escrowAddr = address(factory.newEscrow(poolId));

        PoolEscrow escrow = PoolEscrow(payable(escrowAddr));

        assertEq(escrow.wards(root), 1, "root not authorized");
        assertEq(escrow.wards(gateway), 1, "gateway not authorized");
        assertEq(escrow.wards(balanceSheet), 1, "balanceSheet not authorized");

        assertEq(escrow.wards(address(factory)), 0, "factory still authorized");
        assertEq(escrow.wards(nonWard), 0, "unexpected authorization");
    }

    function testFileSetsBalanceSheet() public {
        factory.file("balanceSheet", randomUser);
        assertEq(factory.balanceSheet(), randomUser);
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
