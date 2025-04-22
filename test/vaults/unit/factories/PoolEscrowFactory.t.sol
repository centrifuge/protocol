// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IAuth} from "src/misc/interfaces/IAuth.sol";

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
    address asyncRequests = makeAddr("asyncRequests");
    address randomUser = makeAddr("randomUser");

    function setUp() public {
        factory = new PoolEscrowFactory(root, deployer);
        factory.file("poolManager", poolManager);
        factory.file("gateway", gateway);
        factory.file("balanceSheet", balanceSheet);
        factory.file("asyncRequests", asyncRequests);
    }

    function testEscrows(uint64 poolId) public {
        assertEq(address(factory.deployedEscrow(poolId)), address(0), "Escrow should not exist yet");
        address escrow = address(factory.newEscrow(poolId));
        assertEq(address(factory.deployedEscrow(poolId)), escrow, "Escrow address mismatch");
    }

    function testDeployEscrowAtDeterministicAddress(uint64 poolId) public {
        address expectedEscrow = address(factory.escrow(poolId));
        address actual = address(factory.newEscrow(poolId));

        assertEq(expectedEscrow, actual, "Escrow address mismatch");
    }

    function testDeployEscrowTwiceReverts(uint64 poolId) public {
        factory.newEscrow(poolId);
        vm.expectRevert(IPoolEscrowFactory.EscrowAlreadyDeployed.selector);
        factory.newEscrow(poolId);
    }

    function testEscrowHasCorrectPermissions(uint64 poolId, address nonWard) public {
        vm.assume(
            nonWard != root && nonWard != gateway && nonWard != poolManager && nonWard != balanceSheet
                && nonWard != asyncRequests
        );
        address escrowAddr = address(factory.newEscrow(poolId));

        PoolEscrow escrow = PoolEscrow(payable(escrowAddr));

        assertEq(escrow.wards(root), 1, "root not authorized");
        assertEq(escrow.wards(gateway), 1, "gateway not authorized");
        assertEq(escrow.wards(poolManager), 1, "poolManager not authorized");
        assertEq(escrow.wards(balanceSheet), 1, "balanceSheet not authorized");
        assertEq(escrow.wards(asyncRequests), 1, "asyncRequests not authorized");

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

    function testFileSetsAsyncRequests() public {
        factory.file("asyncRequests", randomUser);
        assertEq(factory.asyncRequests(), randomUser);
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
