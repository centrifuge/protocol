// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";

import {IPoolEscrowProvider, IPoolEscrowFactory} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import {PoolEscrow} from "src/vaults/Escrow.sol";
import {PoolEscrowFactory} from "src/vaults/factories/PoolEscrowFactory.sol";

contract PoolEscrowFactoryTest is Test {
    PoolEscrowFactory factory;

    address deployer = address(this);
    address root = makeAddr("root");
    address poolManager = makeAddr("poolManager");
    address gateway = makeAddr("gateway");
    address balanceSheet = makeAddr("balanceSheet");
    address asyncRequestManager = makeAddr("asyncRequestManager");
    address randomUser = makeAddr("randomUser");

    function setUp() public {
        factory = new PoolEscrowFactory(root, deployer);
        factory.file("poolManager", poolManager);
        factory.file("gateway", gateway);
        factory.file("balanceSheet", balanceSheet);
        factory.file("asyncRequestManager", asyncRequestManager);
    }

    function testEscrows(PoolId poolId) public {
        assertEq(address(factory.deployedEscrow(poolId)), address(0), "Escrow should not exist yet");
        address escrow = address(factory.newEscrow(poolId));
        assertEq(address(factory.deployedEscrow(poolId)), escrow, "Escrow address mismatch");
    }

    function testDeployEscrowAtDeterministicAddress(PoolId poolId) public {
        address expectedEscrow = address(factory.escrow(poolId));
        address actual = address(factory.newEscrow(poolId));

        assertEq(expectedEscrow, actual, "Escrow address mismatch");
    }

    function testDeployEscrowTwiceReverts(PoolId poolId) public {
        factory.newEscrow(poolId);
        vm.expectRevert(IPoolEscrowFactory.EscrowAlreadyDeployed.selector);
        factory.newEscrow(poolId);
    }

    function testEscrowHasCorrectPermissions(PoolId poolId, address nonWard) public {
        vm.assume(
            nonWard != root && nonWard != gateway && nonWard != poolManager && nonWard != balanceSheet
                && nonWard != asyncRequestManager
        );
        address escrowAddr = address(factory.newEscrow(poolId));

        PoolEscrow escrow = PoolEscrow(payable(escrowAddr));

        assertEq(escrow.wards(root), 1, "root not authorized");
        assertEq(escrow.wards(gateway), 1, "gateway not authorized");
        assertEq(escrow.wards(poolManager), 1, "poolManager not authorized");
        assertEq(escrow.wards(balanceSheet), 1, "balanceSheet not authorized");
        assertEq(escrow.wards(asyncRequestManager), 1, "asyncRequestManager not authorized");

        assertEq(escrow.wards(address(factory)), 0, "factory still authorized");
        assertEq(escrow.wards(nonWard), 0, "unexpected authorization");
    }

    function testFileSetsPoolManager() public {
        factory.file("poolManager", randomUser);
        assertEq(factory.poolManager(), randomUser);
    }

    function testFileSetsBalanceSheet() public {
        factory.file("balanceSheet", randomUser);
        assertEq(factory.balanceSheet(), randomUser);
    }

    function testFileSetsAsyncRequestManager() public {
        factory.file("asyncRequestManager", randomUser);
        assertEq(factory.asyncRequestManager(), randomUser);
    }

    function testFileWithUnknownParamReverts() public {
        vm.expectRevert(IPoolEscrowFactory.FileUnrecognizedParam.selector);
        factory.file("unknown", randomUser);
    }

    function testFileUnauthorizedReverts() public {
        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        factory.file("poolManager", randomUser);
    }
}
