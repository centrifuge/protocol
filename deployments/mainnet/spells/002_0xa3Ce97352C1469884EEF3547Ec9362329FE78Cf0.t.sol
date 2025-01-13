// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {ICentrifugeRouter} from "src/interfaces/ICentrifugeRouter.sol";
import "forge-std/Test.sol";
import "src/002.sol";

interface DelayedAdminLike {
    function scheduleRely(address spell) external;
}

contract SpellTest is Test {
    Spell spell;

    // Details related to pending redemption that is failing
    address investor1 = 0x32f5eF78AA9C7b8882D748331AdcFe0dfA4f1a14;
    address investor2 = 0xbe19e6AdF267248beE015dd3fbBa363E12ca8cE6;
    address vault = 0xa7607A638df0117E6718b93f8cFf53503A815D2f;
    ICentrifugeRouter router = ICentrifugeRouter(0x2F445BA946044C5F508a63eEaF7EAb673c69a1F4);

    IERC20 usdc;

    function setUp() public {
        spell = new Spell();
        usdc = IERC20(spell.USDC());
    }

    function testCastSuccessful() public {
        assertEq(usdc.balanceOf(spell.OLD_ESCROW()), 143360978110);
        assertEq(usdc.balanceOf(spell.NEW_ESCROW()), 0);

        vm.expectRevert(bytes("SafeTransferLib/safe-transfer-from-failed"));
        vm.prank(investor1);
        router.claimRedeem(vault, investor1, investor1);

        vm.expectRevert(bytes("SafeTransferLib/safe-transfer-from-failed"));
        vm.prank(investor2);
        router.claimRedeem(vault, investor2, investor2);

        castSpell();

        assertEq(usdc.balanceOf(spell.OLD_ESCROW()), 0);
        assertEq(usdc.balanceOf(spell.NEW_ESCROW()), 143360978110);

        vm.prank(investor1);
        router.claimRedeem(vault, investor1, investor1);

        vm.prank(investor2);
        router.claimRedeem(vault, investor2, investor2);
    }

    function castSpell() internal {
        // Admin submits a tx to delayedAdmin in order to rely spell -> to be done manually before spell cast
        DelayedAdminLike delayedAdmin = DelayedAdminLike(spell.OLD_DELAYED_ADMIN());
        vm.prank(spell.LP_MULTISIG());
        delayedAdmin.scheduleRely(address(spell));

        // Warp to the time when the spell can be cast -> current block + delay
        vm.warp(block.timestamp + RootLike(spell.OLD_ROOT()).delay());
        RootLike(spell.OLD_ROOT()).executeScheduledRely(address(spell)); // --> to be called after delay has passed
        spell.cast();
    }
}
