// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonDeploymentInputTest} from "../common/Deployment.t.sol";

import {HubDeployer, HubActionBatcher} from "../../script/HubDeployer.s.sol";

import "forge-std/Test.sol";

contract HubDeploymentTest is HubDeployer, CommonDeploymentInputTest {
    function setUp() public {
        HubActionBatcher batcher = new HubActionBatcher();
        deployHub(_commonInput(), batcher);
        removeHubDeployerAccess(batcher);
    }

    function testHub(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(guardian));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(hub.wards(address(root)), 1);
        assertEq(hub.wards(address(guardian)), 1);
        assertEq(hub.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(hub.hubRegistry()), address(hubRegistry));
        assertEq(address(hub.gateway()), address(gateway));
        assertEq(address(hub.holdings()), address(holdings));
        assertEq(address(hub.accounting()), address(accounting));
        assertEq(address(hub.multiAdapter()), address(multiAdapter));
        assertEq(address(hub.shareClassManager()), address(shareClassManager));
        assertEq(address(hub.sender()), address(messageDispatcher));
        assertEq(address(hub.poolEscrowFactory()), address(poolEscrowFactory));
    }

    function testSpokeHandler(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(spokeHandler.wards(address(root)), 1);
        assertEq(hub.wards(address(messageProcessor)), 1);
        assertEq(hub.wards(address(messageDispatcher)), 1);
        assertEq(spokeHandler.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(spokeHandler.hub()), address(hub));
        assertEq(address(spokeHandler.holdings()), address(holdings));
        assertEq(address(spokeHandler.hubRegistry()), address(hubRegistry));
        assertEq(address(spokeHandler.shareClassManager()), address(shareClassManager));
    }

    function testHubRegistry(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(hub));

        assertEq(hubRegistry.wards(address(root)), 1);
        assertEq(hubRegistry.wards(address(hub)), 1);
        assertEq(hubRegistry.wards(nonWard), 0);

        // initial values set correctly
        assertEq(hubRegistry.decimals(USD_ID), ISO4217_DECIMALS);
        assertEq(hubRegistry.decimals(EUR_ID), ISO4217_DECIMALS);
    }

    function testShareClassManager(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(hub));
        vm.assume(nonWard != address(spokeHandler));

        assertEq(shareClassManager.wards(address(root)), 1);
        assertEq(shareClassManager.wards(address(hub)), 1);
        assertEq(shareClassManager.wards(address(spokeHandler)), 1);
        assertEq(shareClassManager.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(shareClassManager.hubRegistry()), address(hubRegistry));
    }

    function testHoldings(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(hub));

        assertEq(holdings.wards(address(root)), 1);
        assertEq(holdings.wards(address(hub)), 1);
        assertEq(holdings.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(holdings.hubRegistry()), address(hubRegistry));
    }

    function testAccounting(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(hub));
        vm.assume(nonWard != address(spokeHandler));

        assertEq(accounting.wards(address(root)), 1);
        assertEq(accounting.wards(address(hub)), 1);
        assertEq(accounting.wards(address(spokeHandler)), 1);
        assertEq(accounting.wards(nonWard), 0);
    }
}

/// This checks the nonWard and the integrity of the common contract after hub changes
contract HubDeploymentCommonExtTest is HubDeploymentTest {
    function testMessageDispatcherExt(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root)); // From common
        vm.assume(nonWard != address(guardian)); // From common
        vm.assume(nonWard != address(hub));
        vm.assume(nonWard != address(spokeHandler));

        assertEq(messageDispatcher.wards(address(hub)), 1);
        assertEq(messageDispatcher.wards(address(spokeHandler)), 1);
        assertEq(messageDispatcher.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(messageDispatcher.hub()), address(hub));
    }

    function testMessageProcessorExt() public view {
        // dependencies set correctly
        assertEq(address(messageProcessor.hub()), address(hub));
    }

    function testGatewayExt(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root)); // From common
        vm.assume(nonWard != address(guardian)); // From common
        vm.assume(nonWard != address(messageDispatcher)); // From common
        vm.assume(nonWard != address(messageProcessor)); // From common
        vm.assume(nonWard != address(multiAdapter)); // From common
        vm.assume(nonWard != address(hub));

        assertEq(gateway.wards(address(hub)), 1);
        assertEq(gateway.wards(nonWard), 0);
    }

    function testPoolEscrowFactoryExt(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root)); // From common
        vm.assume(nonWard != address(hub));

        assertEq(poolEscrowFactory.wards(address(hub)), 1);
        assertEq(poolEscrowFactory.wards(nonWard), 0);
    }

    function testGuardianExt() public view {
        // dependencies set correctly
        assertEq(address(guardian.hub()), address(hub));
    }

    function testMultiAdapterExt(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root)); // From common
        vm.assume(nonWard != address(guardian)); // From common
        vm.assume(nonWard != address(gateway)); // from common
        vm.assume(nonWard != address(messageProcessor)); // from common
        vm.assume(nonWard != address(hub));

        assertEq(multiAdapter.wards(address(hub)), 1);
        assertEq(multiAdapter.wards(nonWard), 0);
    }
}
