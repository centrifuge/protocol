// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {ISyncInvestmentManager} from "src/vaults/interfaces/investments/ISyncInvestmentManager.sol";
import {SyncInvestmentManager} from "src/vaults/SyncInvestmentManager.sol";

import "test/vaults/BaseTest.sol";

contract SyncInvestmentManagerTest is BaseTest {
    using MessageLib for *;

    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(gateway) && nonWard != address(poolManager)
                && nonWard != address(messageDispatcher) && nonWard != address(messageProcessor) && nonWard != address(this)
        );

        // redeploying within test to increase coverage
        new SyncInvestmentManager(address(root), address(escrow));

        // values set correctly
        assertEq(address(syncInvestmentManager.escrow()), address(escrow));
        assertEq(address(syncInvestmentManager.gateway()), address(gateway));
        assertEq(address(syncInvestmentManager.poolManager()), address(poolManager));

        // permissions set correctly
        assertEq(syncInvestmentManager.wards(address(root)), 1);
        assertEq(syncInvestmentManager.wards(address(gateway)), 1);
        assertEq(syncInvestmentManager.wards(address(poolManager)), 1);
        assertEq(syncInvestmentManager.wards(address(messageProcessor)), 1);
        assertEq(syncInvestmentManager.wards(address(messageDispatcher)), 1);
        assertEq(syncInvestmentManager.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(bytes("SyncInvestmentManager/file-unrecognized-param"));
        syncInvestmentManager.file("random", self);

        assertEq(address(syncInvestmentManager.gateway()), address(gateway));
        assertEq(address(syncInvestmentManager.poolManager()), address(poolManager));
        // success
        syncInvestmentManager.file("sender", randomUser);
        assertEq(address(syncInvestmentManager.sender()), randomUser);
        syncInvestmentManager.file("poolManager", randomUser);
        assertEq(address(syncInvestmentManager.poolManager()), randomUser);
        syncInvestmentManager.file("gateway", randomUser);
        assertEq(address(syncInvestmentManager.gateway()), randomUser);

        // remove self from wards
        syncInvestmentManager.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        syncInvestmentManager.file("poolManager", randomUser);
    }

    function testUpdateMaxGasPrice(uint64 maxPriceAge) public {
        vm.assume(maxPriceAge > 0);
        address vault = makeAddr("vault");
        assertEq(syncInvestmentManager.maxPriceAge(vault), 0);

        bytes memory updateMaxPriceAge =
            MessageLib.UpdateContractMaxPriceAge({vault: bytes32(bytes20(vault)), maxPriceAge: maxPriceAge}).serialize();
        bytes memory updateContract = MessageLib.UpdateContract({
            poolId: 0,
            scId: bytes16(0),
            target: bytes32(bytes20(address(syncInvestmentManager))),
            payload: updateMaxPriceAge
        }).serialize();

        vm.expectEmit();
        emit ISyncInvestmentManager.MaxPriceAgeUpdate(vault, maxPriceAge);
        messageProcessor.handle(THIS_CHAIN_ID, updateContract);

        assertEq(syncInvestmentManager.maxPriceAge(vault), maxPriceAge);
    }
}
