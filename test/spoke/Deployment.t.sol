// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SpokeDeployer} from "script/SpokeDeployer.s.sol";

import {CommonDeploymentTest, CommonInput} from "test/common/Deployment.t.sol";

import "forge-std/Test.sol";

contract SpokeDeploymentTest is SpokeDeployer, CommonDeploymentTest {
    function setUp() public virtual override {
        CommonInput memory input = CommonInput({
            centrifugeId: CENTRIFUGE_ID,
            adminSafe: ADMIN_SAFE,
            messageGasLimit: 0,
            maxBatchSize: 0,
            isTests: true
        });

        deploySpoke(input, address(this));
        removeSpokeDeployerAccess(address(this));
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

    function testAsyncRequestManager(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));
        vm.assume(nonWard != address(syncManager));

        assertEq(asyncRequestManager.wards(address(root)), 1);
        assertEq(asyncRequestManager.wards(address(spoke)), 1);
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
        vm.assume(nonWard != address(spoke));
        vm.assume(nonWard != address(syncDepositVaultFactory));

        assertEq(syncManager.wards(address(root)), 1);
        assertEq(syncManager.wards(address(spoke)), 1);
        assertEq(syncManager.wards(address(syncDepositVaultFactory)), 1);
        assertEq(syncManager.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(syncManager.spoke()), address(spoke));
        assertEq(address(syncManager.balanceSheet()), address(balanceSheet));
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
contract SpokeDeploymentCommonExtTest is SpokeDeploymentTest {
    function testMessageDispatcherExt(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(spoke));
        vm.assume(nonWard != address(balanceSheet));
        super.testMessageDispatcher(nonWard);

        assertEq(messageDispatcher.wards(address(spoke)), 1);
        assertEq(messageDispatcher.wards(address(balanceSheet)), 1);

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
        vm.assume(nonWard != address(spoke));
        vm.assume(nonWard != address(balanceSheet));
        vm.assume(nonWard != address(vaultRouter));
        super.testGateway(nonWard);

        assertEq(gateway.wards(address(spoke)), 1);
        assertEq(gateway.wards(address(balanceSheet)), 1);
        assertEq(gateway.wards(address(vaultRouter)), 1);
    }

    function testPoolEscrowFactoryExt(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(spoke));
        super.testPoolEscrowFactory(nonWard);

        assertEq(poolEscrowFactory.wards(address(spoke)), 1);

        // dependencies set correctly
        assertEq(address(poolEscrowFactory.balanceSheet()), address(balanceSheet));
    }
}
