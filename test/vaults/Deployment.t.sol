// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonDeploymentInputTest} from "../common/Deployment.t.sol";

import {VaultsDeployer, VaultsActionBatcher} from "../../script/VaultsDeployer.s.sol";

import "forge-std/Test.sol";

contract VaultsDeploymentTest is VaultsDeployer, CommonDeploymentInputTest {
    function setUp() public {
        VaultsActionBatcher batcher = new VaultsActionBatcher();
        deployVaults(_commonInput(), batcher);
        removeVaultsDeployerAccess(batcher);
    }

    function testRouterEscrow(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(vaultRouter));

        assertEq(routerEscrow.wards(address(root)), 1);
        assertEq(routerEscrow.wards(address(vaultRouter)), 1);
        assertEq(routerEscrow.wards(nonWard), 0);
    }

    function testGlobalEscrow(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(asyncRequestManager));

        assertEq(globalEscrow.wards(address(root)), 1);
        assertEq(globalEscrow.wards(address(asyncRequestManager)), 1);
        assertEq(globalEscrow.wards(nonWard), 0);

        // root endorsements
        assertEq(root.endorsed(address(globalEscrow)), true);
    }

    function testAsyncRequestManager(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));
        vm.assume(nonWard != address(syncDepositVaultFactory));
        vm.assume(nonWard != address(asyncVaultFactory));

        assertEq(asyncRequestManager.wards(address(root)), 1);
        assertEq(asyncRequestManager.wards(address(spoke)), 1);
        assertEq(asyncRequestManager.wards(address(syncDepositVaultFactory)), 1);
        assertEq(asyncRequestManager.wards(address(asyncVaultFactory)), 1);
        assertEq(asyncRequestManager.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(asyncRequestManager.spoke()), address(spoke));
        assertEq(address(asyncRequestManager.balanceSheet()), address(balanceSheet));
        assertEq(address(asyncRequestManager.globalEscrow()), address(globalEscrow));

        // root endorsements
        assertEq(root.endorsed(address(balanceSheet)), true);
    }

    function testAsyncVaultFactory(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(asyncVaultFactory.wards(address(root)), 1);
        assertEq(asyncVaultFactory.wards(address(spoke)), 1);
        assertEq(asyncVaultFactory.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(asyncVaultFactory.root()), address(root));
        assertEq(address(asyncVaultFactory.asyncRequestManager()), address(asyncRequestManager));
    }

    function testSyncDepositVaultFactory(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(syncDepositVaultFactory.wards(address(root)), 1);
        assertEq(syncDepositVaultFactory.wards(address(spoke)), 1);
        assertEq(syncDepositVaultFactory.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(syncDepositVaultFactory.root()), address(root));
        assertEq(address(syncDepositVaultFactory.syncDepositManager()), address(syncManager));
        assertEq(address(syncDepositVaultFactory.asyncRedeemManager()), address(asyncRequestManager));
    }

    function testSyncManager(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(contractUpdater));
        vm.assume(nonWard != address(syncDepositVaultFactory));

        assertEq(syncManager.wards(address(root)), 1);
        assertEq(syncManager.wards(address(contractUpdater)), 1);
        assertEq(syncManager.wards(address(syncDepositVaultFactory)), 1);
        assertEq(syncManager.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(syncManager.spoke()), address(spoke));
        assertEq(address(syncManager.balanceSheet()), address(balanceSheet));
    }

    function testVaultRouter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));

        assertEq(vaultRouter.wards(address(root)), 1);
        assertEq(vaultRouter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(vaultRouter.spoke()), address(spoke));
        assertEq(address(vaultRouter.escrow()), address(routerEscrow));
        assertEq(address(vaultRouter.gateway()), address(gateway));

        // root endorsements
        assertEq(root.endorsed(address(vaultRouter)), true);
    }
}

/// This checks the nonWard and the integrity of the common contract after spoke changes
contract VaultsDeploymentSpokeExtTest is VaultsDeploymentTest {
    function testGatewayExt(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root)); // From common
        vm.assume(nonWard != address(messageDispatcher)); // From common
        vm.assume(nonWard != address(multiAdapter)); // From common
        vm.assume(nonWard != address(spoke)); // From spoke
        vm.assume(nonWard != address(balanceSheet)); // From spoke
        vm.assume(nonWard != address(vaultRouter));

        assertEq(gateway.wards(address(vaultRouter)), 1);
        assertEq(gateway.wards(nonWard), 0);
    }
}
