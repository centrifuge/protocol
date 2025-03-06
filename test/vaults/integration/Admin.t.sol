// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import {MockManager} from "test/vaults/mocks/MockManager.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

contract AdminTest is BaseTest {
    using MessageLib for *;
    using CastLib for *;

    function testDeployment() public view {
        // values set correctly
        assertEq(address(root.escrow()), address(escrow));
        assertEq(root.paused(), false);

        // permissions set correctly
        assertEq(root.wards(address(guardian)), 1);
        assertEq(gateway.wards(address(guardian)), 1);
    }

    function testHandleInvalidMessage() public {
        vm.expectRevert(bytes("Root/invalid-message"));
        root.handle(abi.encodePacked(uint8(MessageType.Invalid)));
    }

    //------ pause tests ------//
    function testUnauthorizedPauseFails() public {
        MockSafe(adminSafe).removeOwner(address(this));
        vm.expectRevert("Guardian/not-the-authorized-safe-or-its-owner");
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
        vm.expectRevert("Guardian/not-the-authorized-safe");
        guardian.unpause();
    }

    function testOutgoingTrancheTokenTransferWhilePausedFails(
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        uint128 assetId,
        address recipient,
        uint128 amount
    ) public {
        // TODO: Set-up correct tests once CC is removed from tests and we test new architecture
    }

    function testIncomingTrancheTokenTransferWhilePausedFails(
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        uint128 assetId,
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
        uint128 assetId,
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
        vm.assume(user != address(this) && user != adminSafe);
        vm.expectRevert("Guardian/not-the-authorized-safe-or-its-owner");
        vm.prank(user);
        guardian.pause();
    }

    function testTimelockWorks() public {
        address spell = vm.addr(1);
        vm.prank(address(adminSafe));
        guardian.scheduleRely(spell);
        vm.warp(block.timestamp + delay + 1 hours);
        root.executeScheduledRely(spell);
        assertEq(root.wards(spell), 1);
    }

    function testTimelockFailsBefore48hours() public {
        address spell = vm.addr(1);
        vm.prank(address(adminSafe));
        guardian.scheduleRely(spell);
        vm.warp(block.timestamp + delay - 1 hours);
        vm.expectRevert("Root/target-not-ready");
        root.executeScheduledRely(spell);
    }

    //------ Root tests ------///
    function testCancellingScheduleBeforeRelyFails() public {
        address spell = vm.addr(1);
        vm.expectRevert("Root/target-not-scheduled");
        root.cancelRely(spell);
    }

    function testCancellingScheduleWorks() public {
        address spell = vm.addr(1);
        vm.prank(address(adminSafe));
        guardian.scheduleRely(spell);
        assertEq(root.schedule(spell), block.timestamp + delay);
        vm.prank(address(adminSafe));
        guardian.cancelRely(spell);
        assertEq(root.schedule(spell), 0);
        vm.warp(block.timestamp + delay + 1 hours);
        vm.expectRevert("Root/target-not-scheduled");
        root.executeScheduledRely(spell);
    }

    function testUnauthorizedCancelFails() public {
        address spell = vm.addr(1);
        vm.prank(address(adminSafe));
        guardian.scheduleRely(spell);
        address badActor = vm.addr(0xBAD);
        vm.expectRevert("Guardian/not-the-authorized-safe");
        vm.prank(badActor);
        guardian.cancelRely(spell);
    }

    function testAddedSafeOwnerCanPause() public {
        address newOwner = vm.addr(0xABCDE);
        MockSafe(adminSafe).addOwner(newOwner);
        vm.prank(newOwner);
        guardian.pause();
        assertEq(root.paused(), true);
    }

    function testRemovedOwnerCannotPause() public {
        MockSafe(adminSafe).removeOwner(address(this));
        assertEq(MockSafe(adminSafe).isOwner(address(this)), false);
        vm.expectRevert("Guardian/not-the-authorized-safe-or-its-owner");
        vm.prank(address(this));
        guardian.pause();
    }

    function testIncomingScheduleUpgradeMessage() public {
        address spell = vm.addr(1);
        centrifugeChain.incomingScheduleUpgrade(spell);
        vm.warp(block.timestamp + delay + 1 hours);
        root.executeScheduledRely(spell);
        assertEq(root.wards(spell), 1);
    }

    function testIncomingCancelUpgradeMessage() public {
        address spell = vm.addr(1);
        centrifugeChain.incomingScheduleUpgrade(spell);
        assertEq(root.schedule(spell), block.timestamp + delay);
        centrifugeChain.incomingCancelUpgrade(spell);
        assertEq(root.schedule(spell), 0);
        vm.warp(block.timestamp + delay + 1 hours);
        vm.expectRevert("Root/target-not-scheduled");
        root.executeScheduledRely(spell);
    }

    //------ Updating delay tests ------///
    function testUpdatingDelayWorks() public {
        vm.prank(address(adminSafe));
        guardian.scheduleRely(address(this));
        vm.warp(block.timestamp + delay + 1 hours);
        root.executeScheduledRely(address(this));
    }

    function testUpdatingDelayWithLargeValueFails() public {
        vm.expectRevert("Root/delay-too-long");
        root.file("delay", 5 weeks);
    }

    function testUpdatingDelayAndExecutingBeforeNewDelayFails() public {
        root.file("delay", 2 hours);
        vm.prank(address(adminSafe));
        guardian.scheduleRely(address(this));
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert("Root/target-not-ready");
        root.executeScheduledRely(address(this));
    }

    function testInvalidFile() public {
        vm.expectRevert("Root/file-unrecognized-param");
        root.file("not-delay", 1);
    }

    //------ rely/denyContract tests ------///
    function testRelyDenyContract() public {
        vm.prank(address(adminSafe));
        guardian.scheduleRely(address(this));
        vm.warp(block.timestamp + delay + 1 hours);
        root.executeScheduledRely(address(this));

        assertEq(investmentManager.wards(address(this)), 1);
        root.denyContract(address(investmentManager), address(this));
        assertEq(investmentManager.wards(address(this)), 0);

        root.relyContract(address(investmentManager), address(this));
        assertEq(investmentManager.wards(address(this)), 1);
    }

    //------ Token Recovery tests ------///
    function testRecoverTokens() public {
        deploySimpleVault();
        address clumsyUser = vm.addr(0x1234);
        address vault_ = investmentManager.getVault(5, bytes16(bytes("1")), defaultAssetId);
        ERC7540Vault vault = ERC7540Vault(vault_);
        address asset_ = vault.asset();
        ERC20 asset = ERC20(asset_);
        deal(asset_, clumsyUser, 300);
        vm.startPrank(clumsyUser);
        asset.transfer(vault_, 100);
        asset.transfer(address(poolManager), 100);
        asset.transfer(address(investmentManager), 100);
        vm.stopPrank();
        assertEq(asset.balanceOf(vault_), 100);
        assertEq(asset.balanceOf(address(poolManager)), 100);
        assertEq(asset.balanceOf(address(investmentManager)), 100);
        assertEq(asset.balanceOf(clumsyUser), 0);
        centrifugeChain.recoverTokens(vault_, asset_, clumsyUser, 100);
        centrifugeChain.recoverTokens(address(poolManager), asset_, clumsyUser, 100);
        centrifugeChain.recoverTokens(address(investmentManager), asset_, clumsyUser, 100);
        assertEq(asset.balanceOf(clumsyUser), 300);
        assertEq(asset.balanceOf(vault_), 0);
        assertEq(asset.balanceOf(address(poolManager)), 0);
        assertEq(asset.balanceOf(address(investmentManager)), 0);
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
        gateway.executeMessageRecovery(address(adapter3), proof);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert("Guardian/not-the-authorized-safe");
        guardian.disputeMessageRecovery(address(adapter3), keccak256(proof));

        // Dispute recovery
        vm.prank(address(adminSafe));
        guardian.disputeMessageRecovery(address(adapter3), keccak256(proof));

        // Check that recovery is not possible anymore
        vm.expectRevert(bytes("Gateway/message-recovery-not-initiated"));
        gateway.executeMessageRecovery(address(adapter3), proof);
        assertEq(poolManager.received(message), 0);
    }

    function _send(MockAdapter adapter, bytes memory message) internal {
        vm.prank(address(adapter));
        gateway.handle(message);
    }

    function _formatMessageProof(bytes memory message) internal pure returns (bytes memory) {
        return MessageLib.MessageProof(keccak256(message)).serialize();
    }
}
