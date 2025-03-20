// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {BalanceSheetManager} from "src/vaults/BalanceSheetManager.sol";

contract BalanceSheetManagerTest is BaseTest {
    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(vaultFactory) && nonWard != address(gateway)
                && nonWard != address(this)
        );

        // redeploying within test to increase coverage
        new BalanceSheetManager(address(escrow));

        // values set correctly
        assertEq(address(balanceSheetManager.escrow()), address(escrow));
        assertEq(address(balanceSheetManager.gateway()), address(gateway));
        assertEq(address(balanceSheetManager.poolManager()), address(poolManager));
        assertEq(address(gateway.handler()), address(balanceSheetManager.sender()));

        // permissions set correctly
        assertEq(balanceSheetManager.wards(address(root)), 1);
        assertEq(balanceSheetManager.wards(address(messageProcessor)), 1);
        assertEq(balanceSheetManager.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(bytes("BalanceSheetManager/file-unrecognized-param"));
        balanceSheetManager.file("random", self);

        assertEq(address(balanceSheetManager.gateway()), address(gateway));
        // success
        balanceSheetManager.file("poolManager", randomUser);
        assertEq(address(balanceSheetManager.poolManager()), randomUser);
        balanceSheetManager.file("gateway", randomUser);
        assertEq(address(balanceSheetManager.gateway()), randomUser);
        balanceSheetManager.file("sender", randomUser);
        assertEq(address(balanceSheetManager.sender()), randomUser);

        // remove self from wards
        balanceSheetManager.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheetManager.file("poolManager", randomUser);
    }
}
