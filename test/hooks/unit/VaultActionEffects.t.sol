// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {VaultActionLib, VaultActionKind, VaultAction} from "../../../src/vaults/libraries/VaultActionLib.sol";

import "forge-std/Test.sol";

import {Role, RoleCheck, Effect} from "../../../src/token/interfaces/IRoleHook.sol";

/// @dev What each vault action tells a hook beyond who: the value that moves, in assets and shares, and what it does
///      to a position, the shares held plus what is pending and claimable, pending redemptions included.
contract VaultActionEffectsTest is Test {
    address controller = makeAddr("controller");
    address owner = makeAddr("owner");
    address receiver = makeAddr("receiver");
    uint128 constant ASSETS = 1_000e6;
    uint128 constant SHARES = 2_000e18;

    function _checks(VaultActionKind kind, address c, address o, address r) internal pure returns (RoleCheck[] memory) {
        return VaultActionLib.roleChecks(VaultAction(kind, c, o, r, ASSETS, SHARES));
    }

    function _assertCheck(RoleCheck memory c, Role role, address from, address to, Effect effect) internal pure {
        assertEq(uint8(c.role), uint8(role), "role");
        assertEq(c.from, from, "from");
        assertEq(c.to, to, "to");
        assertEq(c.assets, ASSETS, "assets");
        assertEq(c.shares, SHARES, "shares");
        assertEq(uint8(c.effect), uint8(effect), "effect");
    }

    function testADepositRequestGrowsTheControllersPosition() public view {
        RoleCheck[] memory c = _checks(VaultActionKind.DepositRequest, controller, owner, controller);
        assertEq(c.length, 1);
        _assertCheck(c[0], Role.Entry, owner, controller, Effect.Grows);
    }

    function testAClaimByTheControllerLeavesItsPositionAsItIs() public view {
        RoleCheck[] memory c = _checks(VaultActionKind.DepositClaim, controller, address(0), controller);
        assertEq(c.length, 2);
        _assertCheck(c[0], Role.Entry, address(0), controller, Effect.Neutral);
        _assertCheck(c[1], Role.Entry, controller, controller, Effect.Neutral);
    }

    function testAClaimToAnotherReceiverMovesThePosition() public view {
        RoleCheck[] memory c = _checks(VaultActionKind.DepositClaim, controller, address(0), receiver);
        _assertCheck(c[0], Role.Entry, address(0), controller, Effect.Neutral);
        _assertCheck(c[1], Role.Entry, controller, receiver, Effect.Moves);
    }

    function testAnInstantDepositGrowsTheReceiverAndTheOwnerOnlyPassesItOn() public view {
        RoleCheck[] memory c = _checks(VaultActionKind.InstantDeposit, owner, owner, receiver);
        _assertCheck(c[0], Role.Entry, address(0), owner, Effect.Neutral);
        _assertCheck(c[1], Role.Entry, owner, receiver, Effect.Grows);
    }

    function testARequestTransferMovesThePositionFromTheSender() public view {
        RoleCheck[] memory c = _checks(VaultActionKind.DepositRequestTransfer, owner, owner, receiver);
        assertEq(c.length, 1);
        _assertCheck(c[0], Role.Entry, owner, receiver, Effect.Moves);
        c = _checks(VaultActionKind.RedeemRequestTransfer, owner, owner, receiver);
        assertEq(c.length, 1);
        _assertCheck(c[0], Role.Exit, owner, receiver, Effect.Moves);
    }

    /// @dev A pending redemption stays in the position, so a cancellation that hands the shares back grows nothing.
    function testARedeemRequestKeepsTheSharesInTheOwnersPosition() public view {
        RoleCheck[] memory c = _checks(VaultActionKind.RedeemRequest, owner, owner, address(0));
        assertEq(c.length, 1);
        _assertCheck(c[0], Role.Exit, address(0), owner, Effect.Neutral);
    }

    function testARedeemRequestForAnotherControllerMovesThePositionToIt() public view {
        RoleCheck[] memory c = _checks(VaultActionKind.RedeemRequest, controller, owner, address(0));
        assertEq(c.length, 2);
        _assertCheck(c[0], Role.Exit, address(0), owner, Effect.Neutral);
        _assertCheck(c[1], Role.Exit, owner, controller, Effect.Moves);
    }

    function testAnInstantRedemptionShrinksTheOwnerAndPaysTheReceiver() public view {
        RoleCheck[] memory c = _checks(VaultActionKind.InstantRedeem, owner, owner, receiver);
        _assertCheck(c[0], Role.Exit, address(0), owner, Effect.Shrinks);
        _assertCheck(c[1], Role.Payout, owner, receiver, Effect.Neutral);
    }

    function testAPayoutAndARefundLeaveThePositionAsItIs() public view {
        RoleCheck[] memory c = _checks(VaultActionKind.RedeemClaim, controller, address(0), receiver);
        _assertCheck(c[0], Role.Payout, controller, receiver, Effect.Neutral);
        c = _checks(VaultActionKind.DepositRefundClaim, controller, address(0), controller);
        _assertCheck(c[0], Role.Refund, address(0), controller, Effect.Neutral);
        c = _checks(VaultActionKind.RedeemRefundClaim, controller, address(0), controller);
        _assertCheck(c[0], Role.Refund, address(0), controller, Effect.Neutral);
    }
}
