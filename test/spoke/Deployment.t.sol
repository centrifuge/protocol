// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {SpokeDeployer} from "script/SpokeDeployer.s.sol";

import {CommonInput} from "test/common/Deployment.t.sol";

import "forge-std/Test.sol";

contract SpokeDeploymentTest is SpokeDeployer, Test {
    function setUp() public {
        CommonInput memory input = CommonInput({
            centrifugeId: 23,
            adminSafe: ISafe(makeAddr("AdminSafe")),
            messageGasLimit: 0,
            maxBatchSize: 0,
            isTests: true
        });

        deploySpoke(input, address(this));
        removeSpokeDeployerAccess(address(this));
    }

    function testTokenFactory(address nonWard) public {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(tokenFactory.wards(address(root)), 1);
        assertEq(tokenFactory.wards(address(spoke)), 1);
        assertEq(tokenFactory.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(tokenFactory.root()), address(root));
        assertEq(address(tokenFactory.tokenWards(0)), address(spoke));
        assertEq(address(tokenFactory.tokenWards(1)), address(balanceSheet));

        vm.expectRevert();
        tokenFactory.tokenWards(2);
    }

    function testSpoke(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(spoke.wards(address(root)), 1);
        assertEq(spoke.wards(address(messageProcessor)), 1);
        assertEq(spoke.wards(address(messageDispatcher)), 1);
        assertEq(spoke.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(spoke.gateway()), address(gateway));
        assertEq(address(spoke.poolEscrowFactory()), address(poolEscrowFactory));
        assertEq(address(spoke.tokenFactory()), address(tokenFactory));
        assertEq(address(spoke.sender()), address(messageDispatcher));
    }

    function testBalanceSheet(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(balanceSheet.wards(address(root)), 1);
        assertEq(balanceSheet.wards(address(messageProcessor)), 1);
        assertEq(balanceSheet.wards(address(messageDispatcher)), 1);
        assertEq(balanceSheet.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(balanceSheet.root()), address(root));
        assertEq(address(balanceSheet.spoke()), address(spoke));
        assertEq(address(balanceSheet.sender()), address(messageDispatcher));
        assertEq(address(balanceSheet.poolEscrowProvider()), address(poolEscrowFactory));

        // root endorsements
        assertEq(root.endorsed(address(balanceSheet)), true);
    }
}

/// This checks the nonWard and the integrity of the common contract after spoke changes
contract SpokeDeploymentCommonExtTest is SpokeDeploymentTest {
    function testMessageDispatcherExt(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root)); // From common
        vm.assume(nonWard != address(guardian)); // From common
        vm.assume(nonWard != address(spoke));
        vm.assume(nonWard != address(balanceSheet));

        assertEq(messageDispatcher.wards(address(spoke)), 1);
        assertEq(messageDispatcher.wards(address(balanceSheet)), 1);
        assertEq(messageDispatcher.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(messageDispatcher.spoke()), address(spoke));
        assertEq(address(messageDispatcher.balanceSheet()), address(balanceSheet));
    }

    function testMessageProcessorExt() public view {
        // dependencies set correctly
        assertEq(address(messageProcessor.spoke()), address(spoke));
        assertEq(address(messageProcessor.balanceSheet()), address(balanceSheet));
    }

    function testGatewayExt(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root)); // From common
        vm.assume(nonWard != address(messageDispatcher)); // From common
        vm.assume(nonWard != address(multiAdapter)); // From common
        vm.assume(nonWard != address(spoke));
        vm.assume(nonWard != address(balanceSheet));

        assertEq(gateway.wards(address(spoke)), 1);
        assertEq(gateway.wards(address(balanceSheet)), 1);
        assertEq(gateway.wards(nonWard), 0);
    }

    function testPoolEscrowFactoryExt(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root)); // From common
        vm.assume(nonWard != address(spoke));

        assertEq(poolEscrowFactory.wards(address(spoke)), 1);
        assertEq(poolEscrowFactory.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(poolEscrowFactory.balanceSheet()), address(balanceSheet));
    }
}
