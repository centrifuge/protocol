// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonDeploymentInputTest} from "../common/Deployment.t.sol";

import {SpokeDeployer, SpokeActionBatcher} from "../../script/SpokeDeployer.s.sol";

import "forge-std/Test.sol";

contract SpokeDeploymentTest is SpokeDeployer, CommonDeploymentInputTest {
    function setUp() public {
        SpokeActionBatcher batcher = new SpokeActionBatcher();
        deploySpoke(_commonInput(), batcher);
        removeSpokeDeployerAccess(batcher);
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

    function testContractUpdater(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(contractUpdater.wards(address(root)), 1);
        assertEq(contractUpdater.wards(address(messageProcessor)), 1);
        assertEq(contractUpdater.wards(address(messageDispatcher)), 1);
        assertEq(contractUpdater.wards(nonWard), 0);
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
        vm.assume(nonWard != address(contractUpdater));

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
        assertEq(address(messageProcessor.contractUpdater()), address(contractUpdater));
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
