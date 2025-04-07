// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {ISyncRequests} from "src/vaults/interfaces/investments/ISyncRequests.sol";
import {SyncRequests} from "src/vaults/SyncRequests.sol";

import "test/vaults/BaseTest.sol";

contract SyncRequestsBaseTest is BaseTest {
    function _assumeUnauthorizedCaller(address nonWard) internal view {
        vm.assume(
            nonWard != address(root) && nonWard != address(poolManager) && nonWard != address(syncDepositVaultFactory)
                && nonWard != address(this)
        );
    }
}

contract SyncRequestsTest is SyncRequestsBaseTest {
    using MessageLib for *;

    // Deployment
    function testDeployment(address nonWard) public {
        _assumeUnauthorizedCaller(nonWard);

        // redeploying within test to increase coverage
        new SyncRequests(address(root), address(escrow));

        // values set correctly
        assertEq(address(syncRequests.escrow()), address(escrow));
        assertEq(address(syncRequests.poolManager()), address(poolManager));
        assertEq(address(syncRequests.balanceSheet()), address(balanceSheet));

        // permissions set correctly
        assertEq(syncRequests.wards(address(root)), 1);
        assertEq(syncRequests.wards(address(poolManager)), 1);
        assertEq(syncRequests.wards(address(syncDepositVaultFactory)), 1);
        assertEq(balanceSheet.wards(address(syncRequests)), 1);
        assertEq(syncRequests.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(bytes("SyncRequests/file-unrecognized-param"));
        syncRequests.file("random", self);

        assertEq(address(syncRequests.poolManager()), address(poolManager));
        assertEq(address(syncRequests.balanceSheet()), address(balanceSheet));

        // success
        syncRequests.file("poolManager", randomUser);
        assertEq(address(syncRequests.poolManager()), randomUser);
        syncRequests.file("balanceSheet", randomUser);
        assertEq(address(syncRequests.balanceSheet()), randomUser);

        // remove self from wards
        syncRequests.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        syncRequests.file("poolManager", randomUser);
    }
}

contract SyncRequestsUnauthorizedTest is SyncRequestsBaseTest {
    function testFileUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequests.file(bytes32(0), address(0));
    }

    function testAddVaultUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequests.addVault(0, bytes16(0), address(0), address(0), 0);
    }

    function testRemoveVaultUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequests.removeVault(0, bytes16(0), address(0), address(0), 0);
    }

    function testDepositUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequests.deposit(address(0), 0, address(0), address(0));
    }

    function testMintUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequests.mint(address(0), 0, address(0), address(0));
    }

    function _expectUnauthorized(address caller) internal {
        vm.assume(caller != address(root) && caller != address(poolManager) && caller != address(this));

        vm.prank(caller);
        vm.expectRevert(IAuth.NotAuthorized.selector);
    }
}
