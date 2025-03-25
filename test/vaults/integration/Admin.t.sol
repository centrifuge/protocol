// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IGuardian} from "src/common/Guardian.sol";

import "test/vaults/BaseTest.sol";
import {MockManager} from "test/common/mocks/MockManager.sol";

contract AdminTest is BaseTest {
    using MessageLib for *;
    using CastLib for *;

    uint32 constant CHAIN_ID = 1;

    function testDeployment() public view {
        // values set correctly
        assertEq(root.paused(), false);

        // permissions set correctly
        assertEq(root.wards(address(guardian)), 1);
        assertEq(gateway.wards(address(guardian)), 1);
    }

    //------ pause tests ------//
    function testUnauthorizedPauseFails() public {
        MockSafe(address(adminSafe)).removeOwner(address(this));
        vm.expectRevert(IGuardian.NotTheAuthorizedSafeOrItsOwner.selector);
        guardian.pause();
    }

    function testPauseWorks() public {
        guardian.pause();
        assertEq(root.paused(), true);
    }

    function testUnpauseWorks() public {
        vm.prank(address(adminSafe));
        guardian.unpause();
        assertEq(root.paused(), false);
    }

    function testUnauthorizedUnpauseFails() public {
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.unpause();
    }

    function testOutgoingTrancheTokenTransferWhilePausedFails(
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        address recipient,
        uint128 amount
    ) public {
        // TODO: Set-up correct tests once CC is removed from tests and we test new architecture
    }

    function testIncomingTrancheTokenTransferWhilePausedFails(
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        bytes32, /*sender*/
        address recipient,
        uint128 amount
    ) public {
        // TODO: Set-up correct tests once CC is removed from tests and we test new architecture
    }

    function testUnpausingResumesFunctionality(
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        bytes32, /*sender*/
        address recipient,
        uint128 amount
    ) public {
        // TODO: Set-up correct tests once CC is removed from tests and we test new architecture
    }

    //------ Guardian tests ------///
    function testGuardianPause() public {
        guardian.pause();
        assertEq(root.paused(), true);
    }

    function testGuardianUnpause() public {
        guardian.pause();
        vm.prank(address(adminSafe));
        guardian.unpause();
        assertEq(root.paused(), false);
    }

    function testGuardianPauseAuth(address user) public {
        vm.assume(user != address(this) && user != address(adminSafe));
        vm.expectRevert(IGuardian.NotTheAuthorizedSafeOrItsOwner.selector);
        vm.prank(user);
        guardian.pause();
    }

    function testTimelockWorks() public {
        address spell = vm.addr(1);
        vm.prank(address(adminSafe));
        guardian.scheduleRely(spell);
        vm.warp(block.timestamp + DELAY + 1 hours);
        root.executeScheduledRely(spell);
        assertEq(root.wards(spell), 1);
    }

    function testTimelockFailsBefore48hours() public {
        address spell = vm.addr(1);
        vm.prank(address(adminSafe));
        guardian.scheduleRely(spell);
        vm.warp(block.timestamp + DELAY - 1 hours);
        vm.expectRevert(IRoot.TargetNotReady.selector);
        root.executeScheduledRely(spell);
    }

    //------ Root tests ------///
    function testCancellingScheduleBeforeRelyFails() public {
        address spell = vm.addr(1);
        vm.expectRevert(IRoot.TargetNotScheduled.selector);
        root.cancelRely(spell);
    }

    function testCancellingScheduleWorks() public {
        address spell = vm.addr(1);
        vm.prank(address(adminSafe));
        guardian.scheduleRely(spell);
        assertEq(root.schedule(spell), block.timestamp + DELAY);
        vm.prank(address(adminSafe));
        guardian.cancelRely(spell);
        assertEq(root.schedule(spell), 0);
        vm.warp(block.timestamp + DELAY + 1 hours);
        vm.expectRevert(IRoot.TargetNotScheduled.selector);
        root.executeScheduledRely(spell);
    }

    function testUnauthorizedCancelFails() public {
        address spell = vm.addr(1);
        vm.prank(address(adminSafe));
        guardian.scheduleRely(spell);
        address badActor = vm.addr(0xBAD);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        vm.prank(badActor);
        guardian.cancelRely(spell);
    }

    function testAddedSafeOwnerCanPause() public {
        address newOwner = vm.addr(0xABCDE);
        MockSafe(address(adminSafe)).addOwner(newOwner);
        vm.prank(newOwner);
        guardian.pause();
        assertEq(root.paused(), true);
    }

    function testRemovedOwnerCannotPause() public {
        MockSafe(address(adminSafe)).removeOwner(address(this));
        assertEq(MockSafe(address(adminSafe)).isOwner(address(this)), false);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafeOrItsOwner.selector);
        vm.prank(address(this));
        guardian.pause();
    }

    function testIncomingScheduleUpgradeMessage() public {
        address spell = vm.addr(1);
        centrifugeChain.incomingScheduleUpgrade(spell);
        vm.warp(block.timestamp + DELAY + 1 hours);
        root.executeScheduledRely(spell);
        assertEq(root.wards(spell), 1);
    }

    function testIncomingCancelUpgradeMessage() public {
        address spell = vm.addr(1);
        centrifugeChain.incomingScheduleUpgrade(spell);
        assertEq(root.schedule(spell), block.timestamp + DELAY);
        centrifugeChain.incomingCancelUpgrade(spell);
        assertEq(root.schedule(spell), 0);
        vm.warp(block.timestamp + DELAY + 1 hours);
        vm.expectRevert(IRoot.TargetNotScheduled.selector);
        root.executeScheduledRely(spell);
    }

    //------ Updating DELAY tests ------///
    function testUpdatingDelayWorks() public {
        vm.prank(address(adminSafe));
        guardian.scheduleRely(address(this));
        vm.warp(block.timestamp + DELAY + 1 hours);
        root.executeScheduledRely(address(this));
    }

    function testUpdatingDelayWithLargeValueFails() public {
        vm.expectRevert(IRoot.DelayTooLong.selector);
        root.file("delay", 5 weeks);
    }

    function testUpdatingDelayAndExecutingBeforeNewDelayFails() public {
        root.file("delay", 2 hours);
        vm.prank(address(adminSafe));
        guardian.scheduleRely(address(this));
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(IRoot.TargetNotReady.selector);
        root.executeScheduledRely(address(this));
    }

    function testInvalidFile() public {
        vm.expectRevert(IRoot.FileUnrecognizedParam.selector);
        root.file("not-delay", 1);
    }

    //------ rely/denyContract tests ------///
    function testRelyDenyContract() public {
        vm.prank(address(adminSafe));
        guardian.scheduleRely(address(this));
        vm.warp(block.timestamp + DELAY + 1 hours);
        root.executeScheduledRely(address(this));

        assertEq(asyncInvestmentManager.wards(address(this)), 1);
        root.denyContract(address(asyncInvestmentManager), address(this));
        assertEq(asyncInvestmentManager.wards(address(this)), 0);

        root.relyContract(address(asyncInvestmentManager), address(this));
        assertEq(asyncInvestmentManager.wards(address(this)), 1);
    }

    //------ Token Recovery tests ------///
    function testRecoverTokens() public {
        deploySimpleAsyncVault();
        address clumsyUser = vm.addr(0x1234);
        address vault_ =
            asyncInvestmentManager.vault(5, bytes16(bytes("1")), poolManager.assetToId(address(erc20), erc20TokenId));
        ERC7540Vault vault = ERC7540Vault(vault_);
        address asset_ = vault.asset();
        ERC20 asset = ERC20(asset_);
        deal(asset_, clumsyUser, 300);
        vm.startPrank(clumsyUser);
        asset.transfer(vault_, 100);
        asset.transfer(address(poolManager), 100);
        asset.transfer(address(asyncInvestmentManager), 100);
        vm.stopPrank();
        assertEq(asset.balanceOf(vault_), 100);
        assertEq(asset.balanceOf(address(poolManager)), 100);
        assertEq(asset.balanceOf(address(asyncInvestmentManager)), 100);
        assertEq(asset.balanceOf(clumsyUser), 0);
        centrifugeChain.recoverTokens(vault_, asset_, erc20TokenId, clumsyUser, 100);
        centrifugeChain.recoverTokens(address(poolManager), asset_, erc20TokenId, clumsyUser, 100);
        centrifugeChain.recoverTokens(address(asyncInvestmentManager), asset_, erc20TokenId, clumsyUser, 100);
        assertEq(asset.balanceOf(clumsyUser), 300);
        assertEq(asset.balanceOf(vault_), 0);
        assertEq(asset.balanceOf(address(poolManager)), 0);
        assertEq(asset.balanceOf(address(asyncInvestmentManager)), 0);
    }

    //Endorsements
    function testEndorseVeto() public {
        address endorser = makeAddr("endorser");

        // endorse
        address router = makeAddr("router");

        root.rely(endorser);
        vm.prank(endorser);
        root.endorse(router);
        assertEq(root.endorsements(router), 1);
        assertEq(root.endorsed(router), true);

        // veto
        root.deny(endorser);
        vm.expectRevert(IAuth.NotAuthorized.selector); // fail no auth permissions
        vm.prank(endorser);
        root.veto(router);

        root.rely(endorser);
        vm.prank(endorser);
        root.veto(router);
        assertEq(root.endorsements(router), 0);
        assertEq(root.endorsed(router), false);
    }

    /* TODO: Uncomment when guardian has access again to dispute messages
    function testDisputeRecovery() public {
        MockManager poolManager = new MockManager();
        gateway.file("adapters", testAdapters);

        bytes memory message = MessageLib.NotifyPool(1).serialize();
        bytes memory proof = _formatMessageProof(message);

        // Only send through 2 out of 3 adapters
        _send(adapter1, message);
        _send(adapter2, proof);
        assertEq(poolManager.received(message), 0);

        // Initiate recovery
    _send(adapter1, MessageLib.InitiateMessageRecovery(keccak256(proof), address(adapter3).toBytes32()).serialize());

        vm.expectRevert(bytes("Gateway/challenge-period-has-not-ended"));
        gateway.executeMessageRecovery(adapter3, proof);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.disputeMessageRecovery(adapter3, keccak256(proof));

        // Dispute recovery
        vm.prank(address(adminSafe));
        guardian.disputeMessageRecovery(adapter3, keccak256(proof));

        // Check that recovery is not possible anymore
        vm.expectRevert(bytes("Gateway/message-recovery-not-initiated"));
        gateway.executeMessageRecovery(adapter3, proof);
        assertEq(poolManager.received(message), 0);
    }
    */

    function _send(MockAdapter adapter, bytes memory message) internal {
        vm.prank(address(adapter));
        gateway.handle(CHAIN_ID, message);
    }

    function _formatMessageProof(bytes memory message) internal pure returns (bytes memory) {
        return MessageLib.MessageProof(keccak256(message)).serialize();
    }
}
