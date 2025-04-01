// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {ISyncRequests} from "src/vaults/interfaces/investments/ISyncRequests.sol";
import {SyncRequests} from "src/vaults/SyncRequests.sol";

import "test/vaults/BaseTest.sol";

contract SyncRequestsTest is BaseTest {
    using MessageLib for *;

    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(nonWard != address(root) && nonWard != address(poolManager) && nonWard != address(this));

        // redeploying within test to increase coverage
        new SyncRequests(address(root), address(escrow));

        // values set correctly
        assertEq(address(syncRequests.escrow()), address(escrow));
        assertEq(address(syncRequests.poolManager()), address(poolManager));
        assertEq(address(syncRequests.balanceSheetManager()), address(balanceSheetManager));

        // permissions set correctly
        assertEq(syncRequests.wards(address(root)), 1);
        assertEq(syncRequests.wards(address(poolManager)), 1);
        assertEq(syncRequests.wards(address(syncDepositVaultFactory)), 1);
        assertEq(balanceSheetManager.wards(address(syncRequests)), 1);
        assertEq(syncRequests.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(bytes("SyncRequests/file-unrecognized-param"));
        syncRequests.file("random", self);

        assertEq(address(syncRequests.poolManager()), address(poolManager));
        assertEq(address(syncRequests.balanceSheetManager()), address(balanceSheetManager));

        // success
        syncRequests.file("poolManager", randomUser);
        assertEq(address(syncRequests.poolManager()), randomUser);
        syncRequests.file("balanceSheetManager", randomUser);
        assertEq(address(syncRequests.balanceSheetManager()), randomUser);

        // remove self from wards
        syncRequests.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        syncRequests.file("poolManager", randomUser);
    }

    function testUpdateMaxGasPrice(uint64 maxPriceAge) public {
        vm.assume(maxPriceAge > 0);
        address vault = makeAddr("vault");
        assertEq(syncRequests.maxPriceAge(vault), 0);

        bytes memory updateMaxPriceAge =
            MessageLib.UpdateContractMaxPriceAge({vault: bytes32(bytes20(vault)), maxPriceAge: maxPriceAge}).serialize();
        bytes memory updateContract = MessageLib.UpdateContract({
            poolId: 0,
            scId: bytes16(0),
            target: bytes32(bytes20(address(syncRequests))),
            payload: updateMaxPriceAge
        }).serialize();

        vm.expectEmit();
        emit ISyncRequests.MaxPriceAgeUpdate(vault, maxPriceAge);
        messageProcessor.handle(THIS_CHAIN_ID, updateContract);

        assertEq(syncRequests.maxPriceAge(vault), maxPriceAge);
    }
}

contract SyncRequestsUnauthorizedTest is BaseTest {
    function testFileUnauthorized(address caller) public {
        _expectUnauthorized(caller);
        syncRequests.file(bytes32(0), address(0));
    }

    function testAddVaultUnauthorized(address caller) public {
        _expectUnauthorized(caller);
        syncRequests.addVault(0, bytes16(0), address(0), address(0), 0);
    }

    function testRemoveVaultUnauthorized(address caller) public {
        _expectUnauthorized(caller);
        syncRequests.removeVault(0, bytes16(0), address(0), address(0), 0);
    }

    function testDepositUnauthorized(address caller) public {
        _expectUnauthorized(caller);
        syncRequests.deposit(address(0), 0, address(0), address(0));
    }

    function testMintUnauthorized(address caller) public {
        _expectUnauthorized(caller);
        syncRequests.mint(address(0), 0, address(0), address(0));
    }

    function testUpdateUnauthorized(address caller) public {
        _expectUnauthorized(caller);
        syncRequests.update(0, bytes16(0), bytes(""));
    }

    function _expectUnauthorized(address caller) internal {
        vm.assume(caller != address(root) && caller != address(poolManager) && caller != address(this));

        vm.prank(caller);
        vm.expectRevert(IAuth.NotAuthorized.selector);
    }
}
