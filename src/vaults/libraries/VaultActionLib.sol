// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IShareToken} from "../../token/interfaces/IShareToken.sol";
import {IRoleHook, Role, RoleCheck, Effect} from "../../token/interfaces/IRoleHook.sol";

/// @notice The vault operations the share token's hook gates: those without an enforced share leg, and the two whose
///         leg the transfer hook sees without the parties the vault knows (an instant deposit's issuance, a deposit
///         claim's delivery). Every other share movement reaches the hook as an ERC20 transfer.
enum VaultActionKind {
    /// @dev `controller` requests a deposit with assets from `owner`.
    DepositRequest,
    /// @dev `controller` claims the shares of a settled deposit, delivered to `receiver`. The delivery is an escrow to
    ///      receiver transfer, which the transfer hook sees without the controller, so the controller is checked here:
    ///      it must be able to hold the shares itself, so a restricted controller cannot move its position away.
    DepositClaim,
    /// @dev `owner`, the caller and `controller`, deposits at once, issued to `receiver`.
    InstantDeposit,
    /// @dev `owner` hands its pending deposit position to `receiver` (ERC-8161).
    DepositRequestTransfer,
    /// @dev `controller` requests the redemption of shares owned by `owner`.
    RedeemRequest,
    /// @dev `controller` claims redemption proceeds, paid out to `receiver`.
    RedeemClaim,
    /// @dev `owner`, the caller and `controller`, redeems at once, paid out to `receiver`.
    InstantRedeem,
    /// @dev `owner` hands its pending redeem position to `receiver` (ERC-8161).
    RedeemRequestTransfer,
    /// @dev `controller` takes back to itself, through `withdraw`, the assets of a cancelled deposit. A refund to
    ///      another receiver is a claim.
    DepositRefundClaim,
    /// @dev `controller` takes back to itself, through `mint`, the shares of a cancelled redemption. A request's owner
    ///      and controller may differ, and the refund goes to the controller, so a hook whose `Refund` is looser than
    ///      its `Transfer` lets the controller receive shares it could not have been sent. A refund to another
    ///      receiver is a claim.
    RedeemRefundClaim
}

/// @notice A vault action and the parties and value it involves. Which party each field names, and which are unused, is
///         the kind's (see `VaultActionKind`). `assets` and `shares` are the value the action moves (see `RoleCheck`).
struct VaultAction {
    VaultActionKind kind;
    address controller;
    address owner;
    address receiver;
    uint128 assets;
    uint128 shares;
}

/// @title  Vault Action Library
/// @notice Turns a vault action into the role checks the share token's hook answers, so the hook knows roles and
///         accounts, and only the vault knows what its actions are.
library VaultActionLib {
    /// @notice A kind this library maps to no role checks, which fails closed.
    error UnknownActionKind();

    /// @notice Asks the token's current hook, so restrictions follow the token. Any answer but the selector fails
    ///         closed.
    function enforce(address token, VaultAction memory action) internal {
        address hook = IShareToken(token).hook();
        if (hook == address(0)) return;

        bytes4 answer = IRoleHook(hook).onRoles(token, roleChecks(action));
        require(answer == IRoleHook.onRoles.selector, IShareToken.RestrictionsFailed());
    }

    /// @notice View twin of `enforce`, through the hook's `checkRoles`.
    function check(address token, VaultAction memory action) internal view returns (bool) {
        address hook = IShareToken(token).hook();
        if (hook == address(0)) return true;

        return IRoleHook(hook).checkRoles(token, roleChecks(action));
    }

    /// @notice The hook's limits on the action at the given capacity (see `IRoleHook.maxAllowed`); none without a hook.
    function limits(address token, VaultAction memory action)
        internal
        view
        returns (uint256 maxAssets, uint256 maxShares)
    {
        address hook = IShareToken(token).hook();
        if (hook == address(0)) return (type(uint256).max, type(uint256).max);

        return IRoleHook(hook).maxAllowed(token, roleChecks(action));
    }

    /// @notice What each action asks: the party taking the shares, the position or the proceeds answers to the role,
    ///         with the party it takes them from. A party that answers on its own, with no one it takes from, is
    ///         checked from zero. Every check carries the action's value in both units, and its `Effect`.
    function roleChecks(VaultAction memory action) internal pure returns (RoleCheck[] memory checks) {
        checks = _parties(action.kind, action.controller, action.owner, action.receiver);
        for (uint256 i; i < checks.length; i++) {
            checks[i].assets = action.assets;
            checks[i].shares = action.shares;
        }
    }

    function _parties(VaultActionKind kind, address controller, address owner, address receiver)
        private
        pure
        returns (RoleCheck[] memory)
    {
        if (kind == VaultActionKind.DepositRequest) {
            return _one(_check(Role.Entry, owner, controller, Effect.Grows));
        }
        if (kind == VaultActionKind.DepositClaim) {
            return _two(
                _check(Role.Entry, address(0), controller, Effect.Neutral),
                _check(Role.Entry, controller, receiver, receiver == controller ? Effect.Neutral : Effect.Moves)
            );
        }
        if (kind == VaultActionKind.InstantDeposit) {
            return _two(
                _check(Role.Entry, address(0), owner, Effect.Neutral), _check(Role.Entry, owner, receiver, Effect.Grows)
            );
        }
        if (kind == VaultActionKind.DepositRequestTransfer) {
            return _one(_check(Role.Entry, owner, receiver, Effect.Moves));
        }

        // Both the owner and a distinct controller of a redemption leave the pool. The shares stay in the position
        // while pending: the owner's own, or moved to the controller's.
        if (kind == VaultActionKind.RedeemRequest) {
            RoleCheck memory exit = _check(Role.Exit, address(0), owner, Effect.Neutral);
            if (controller == owner) return _one(exit);
            return _two(exit, _check(Role.Exit, owner, controller, Effect.Moves));
        }
        if (kind == VaultActionKind.RedeemClaim) {
            return _one(_check(Role.Payout, controller, receiver, Effect.Neutral));
        }
        if (kind == VaultActionKind.InstantRedeem) {
            return _two(
                _check(Role.Exit, address(0), owner, Effect.Shrinks),
                _check(Role.Payout, owner, receiver, Effect.Neutral)
            );
        }
        if (kind == VaultActionKind.RedeemRequestTransfer) {
            return _one(_check(Role.Exit, owner, receiver, Effect.Moves));
        }
        if (kind == VaultActionKind.DepositRefundClaim || kind == VaultActionKind.RedeemRefundClaim) {
            return _one(_check(Role.Refund, address(0), controller, Effect.Neutral));
        }
        revert UnknownActionKind();
    }

    /// @dev The amounts are filled in by `roleChecks`, the same for every check of an action.
    function _check(Role role, address from, address to, Effect effect) private pure returns (RoleCheck memory) {
        return RoleCheck(role, from, to, 0, 0, effect);
    }

    function _one(RoleCheck memory c) private pure returns (RoleCheck[] memory checks) {
        checks = new RoleCheck[](1);
        checks[0] = c;
    }

    function _two(RoleCheck memory c0, RoleCheck memory c1) private pure returns (RoleCheck[] memory checks) {
        checks = new RoleCheck[](2);
        checks[0] = c0;
        checks[1] = c1;
    }
}
