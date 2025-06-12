// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/spoke/BaseTest.sol";

import {BalanceSheet} from "src/spoke/BalanceSheet.sol";

contract BalanceSheetTest is BaseTest {
    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(asyncRequestManager)
                && nonWard != address(syncRequestManager) && nonWard != address(messageProcessor)
                && nonWard != address(messageDispatcher) && nonWard != address(this)
        );

        // redeploying within test to increase coverage
        new BalanceSheet(root, address(this));

        // values set correctly
        assertEq(address(balanceSheet.root()), address(root));
        assertEq(address(balanceSheet.spoke()), address(spoke));
        assertEq(address(balanceSheet.sender()), address(messageDispatcher));
        assertEq(address(balanceSheet.poolEscrowProvider()), address(poolEscrowFactory));

        // permissions set correctly
        assertEq(balanceSheet.wards(address(root)), 1);
        assertEq(balanceSheet.wards(address(asyncRequestManager)), 1);
        assertEq(balanceSheet.wards(address(syncRequestManager)), 1);
        assertEq(balanceSheet.wards(address(messageProcessor)), 1);
        assertEq(balanceSheet.wards(address(messageDispatcher)), 1);
        assertEq(balanceSheet.wards(nonWard), 0);
    }
}
