// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {ISyncManager} from "src/vaults/interfaces/investments/ISyncManager.sol";
import {SyncManager} from "src/vaults/SyncManager.sol";

import "test/vaults/BaseTest.sol";

contract SyncManagerTest is BaseTest {
    using MessageLib for *;

    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(nonWard != address(root) && nonWard != address(poolManager) && nonWard != address(this));

        // redeploying within test to increase coverage
        new SyncManager(address(root), address(escrow));

        // values set correctly
        assertEq(address(syncManager.escrow()), address(escrow));
        assertEq(address(syncManager.poolManager()), address(poolManager));
        assertEq(address(syncManager.balanceSheetManager()), address(balanceSheetManager));

        // permissions set correctly
        assertEq(syncManager.wards(address(root)), 1);
        assertEq(syncManager.wards(address(poolManager)), 1);
        assertEq(syncManager.wards(address(syncDepositVaultFactory)), 1);
        assertEq(balanceSheetManager.wards(address(syncManager)), 1);
        assertEq(syncManager.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(bytes("SyncManager/file-unrecognized-param"));
        syncManager.file("random", self);

        assertEq(address(syncManager.poolManager()), address(poolManager));
        assertEq(address(syncManager.balanceSheetManager()), address(balanceSheetManager));

        // success
        syncManager.file("poolManager", randomUser);
        assertEq(address(syncManager.poolManager()), randomUser);
        syncManager.file("balanceSheetManager", randomUser);
        assertEq(address(syncManager.balanceSheetManager()), randomUser);

        // remove self from wards
        syncManager.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        syncManager.file("poolManager", randomUser);
    }

    function testUpdateMaxGasPrice(uint64 maxPriceAge) public {
        vm.assume(maxPriceAge > 0);
        address vault = makeAddr("vault");
        assertEq(syncManager.maxPriceAge(vault), 0);

        bytes memory updateMaxPriceAge =
            MessageLib.UpdateContractMaxPriceAge({vault: bytes32(bytes20(vault)), maxPriceAge: maxPriceAge}).serialize();
        bytes memory updateContract = MessageLib.UpdateContract({
            poolId: 0,
            scId: bytes16(0),
            target: bytes32(bytes20(address(syncManager))),
            payload: updateMaxPriceAge
        }).serialize();

        vm.expectEmit();
        emit ISyncManager.MaxPriceAgeUpdate(vault, maxPriceAge);
        messageProcessor.handle(THIS_CHAIN_ID, updateContract);

        assertEq(syncManager.maxPriceAge(vault), maxPriceAge);
    }
}

contract SyncManagerUnauthorizedTest is BaseTest {
    function testFileUnauthorized(address caller) public {
        _expectUnauthorized(caller);
        syncManager.file(bytes32(0), address(0));
    }

    function testAddVaultUnauthorized(address caller) public {
        _expectUnauthorized(caller);
        syncManager.addVault(0, bytes16(0), address(0), address(0), 0);
    }

    function testRemoveVaultUnauthorized(address caller) public {
        _expectUnauthorized(caller);
        syncManager.removeVault(0, bytes16(0), address(0), address(0), 0);
    }

    function testDepositUnauthorized(address caller) public {
        _expectUnauthorized(caller);
        syncManager.deposit(address(0), 0, address(0), address(0));
    }

    function testMintUnauthorized(address caller) public {
        _expectUnauthorized(caller);
        syncManager.mint(address(0), 0, address(0), address(0));
    }

    function testUpdateUnauthorized(address caller) public {
        _expectUnauthorized(caller);
        syncManager.update(0, bytes16(0), bytes(""));
    }

    function _expectUnauthorized(address caller) internal {
        vm.assume(caller != address(root) && caller != address(poolManager) && caller != address(this));

        vm.prank(caller);
        vm.expectRevert(IAuth.NotAuthorized.selector);
    }
}
