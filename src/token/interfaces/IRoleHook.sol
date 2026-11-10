// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC165} from "../../misc/interfaces/IERC7575.sol";

/// @notice A requirement an account answers to on a share token. The hook decides what each role asks: the reference
///         hook asks membership of the roles its policy mask sets, and refuses a frozen account in every role.
/// @dev    Some refusals trap value an investor already put in, so a hook refuses those only for what it exists to
///         enforce (a freeze, a sanction), and never by reverting or running out of gas, which refuses every role:
///         - `Exit`, `Payout` and `Refund` can trap funds: shares that cannot be redeemed, proceeds that cannot be
///           paid, a cancelled amount that cannot be taken back. The reference hook asks no membership for `Refund`.
///         - `Entry` traps funds on a deposit claim, a `Neutral` check of the controller: the filled shares stay in
///           the escrow. On a request or an instant deposit (`Grows`) it only turns new money away.
///         - `Transfer` holds shares where they are; the holder can still exit.
///         - `Burn` is not asked of an investor on any vault path.
///         - A cross-chain receipt reaches the transfer hook, not a role check, and a refusal there traps shares the
///           source already burned.
enum Role {
    /// @dev Taking shares, or a position that turns into shares: an issuance, a delivery out of an escrow
    Entry,
    /// @dev Taking shares from another holder
    Transfer,
    /// @dev Leaving the pool: giving up shares, or a position, to be redeemed
    Exit,
    /// @dev Burning shares outside a redemption
    Burn,
    /// @dev Receiving the proceeds of a redemption
    Payout,
    /// @dev Taking back what the account itself put in
    Refund
}

/// @notice What a check does to a position. An account's position is the shares it holds, plus what it has pending
///         and claimable on the token's vaults: `balanceOf`, `pendingDepositRequest` at the price, `claimableMint`
///         (cancelled redemptions included) and `pendingRedeemRequest`. A cancellation moves value between those
///         views and never grows a position, so it asks no check. A redemption's position ends when it is filled.
enum Effect {
    /// @dev The position of `to` grows by the check's `shares`: a deposit request, an instant deposit's receiver. It
    ///      is the zero value, so a check built without an `effect` is limited rather than skipped.
    Grows,
    /// @dev The position of `to` stays as it is: the value is already in it (a claim by the controller, a redeem
    ///      request by the owner of the shares), `to` only passes it on, or it is paid out.
    Neutral,
    /// @dev The position of `to` shrinks by the check's `shares`: an instant redemption's shares, which leave at once.
    Shrinks,
    /// @dev A position of the check's `shares` moves from `from` to `to`: a request transfer, a claim delivered to
    ///      another account, a redeem request whose controller is not the owner.
    Moves
}

/// @notice One requirement a caller asks of a hook: `to` answers to `role` for value coming from `from`, or from none
///         when `from` is zero.
/// @dev    `assets` and `shares` are the value that moves, in both units, and `effect` what it does to positions, so a
///         hook that limits a position, an exit or a payout reads these and needs no knowledge of vault actions, and
///         no price of its own. The vault fills in the exact figure where it has one (an instant trade, a claim, a
///         payout) and the other at the current price. While the price is not vouched for (before the first price,
///         paused, stale, skewed) that estimate is `type(uint128).max`, so a limit refuses rather than passes. An
///         exit limit therefore reads `shares`, exact on a redeem request, and never `assets`, which would refuse
///         every exit. An exit reads as `Exit` from no one: the owner's shares leave.
///         Some growth also has a share leg the transfer hook sees after the check: an instant deposit's issuance
///         (`IShareTokenHook.Kind.Mint`) and a claim's delivery out of the escrow (`Kind.Release`). A hook that limits
///         a position counts it once, here, and on the transfer callback limits only the movements no role check
///         covers: `Kind.Transfer` to an investor, such as a holder's transfer. A cross-chain receipt is not limited
///         (`from` is the cross-chain source): the source has burned the shares and cannot see the position here,
///         so a refusal traps them in the gateway until it passes. The two run
///         at different times: role checks before the vault changes state, the transfer callback after the token
///         moved the shares (its view twin, `checkTransferRestriction`, before), so a balance read in the callback
///         already includes the value.
struct RoleCheck {
    Role role;
    address from;
    address to;
    uint128 assets;
    uint128 shares;
    Effect effect;
}

/// @title  IRoleHook
/// @notice Role checks a share token's hook answers for value that moves without an ERC20 leg the transfer hook sees,
///         such as a request, a claim or a redemption payout. The caller decides which roles an operation asks and
///         of whom; the hook decides who meets a role.
/// @dev    A check names `to`, the account that answers to `role`, and `from`, the account the value comes from, or
///         zero when it comes from none. The hook may relate the two, as a class that only hands over to its own
///         class does. A hook on a token traded through vaults MUST implement it, or every vault action reverts.
///         A caller may be an endorsed relay (the investor router, a fund-of-funds route) that stands between the
///         parties, as `owner` or `receiver`. A hook that relates `from` and `to` MUST treat an endorsed relay like an
///         escrow, since a relay has no class of its own and the value it carries was already checked against the
///         investor it acts for.
interface IRoleHook is IERC165 {
    /// @notice Enforces every check on `token`; MUST revert when one is not met.
    /// @dev    The checks run before the vault changes state, so a hook that reads the vault's views for a position
    ///         sees it without the effect of the checks, and adds it. That holds for every action: a claim runs its
    ///         checks before the ledger is debited, and a fold the vault runs first only moves value from pending to
    ///         claimable, which a position counts once. A stateful hook MUST NOT add figures across checks, which can
    ///         name the same value twice (a claim's controller and its receiver). The reference hook ignores the
    ///         figures and the effect.
    /// @dev    The reference hook is stateless and accepts any caller. A stateful hook MUST check that `msg.sender`
    ///         is a contract it serves for `token`, and key its state by that, not by anything the caller passes.
    ///         The checks are one operation, so a hook may judge them together.
    /// @return The function selector, which the caller requires, so a contract without this surface (one with a
    ///         permissive fallback included) fails closed.
    function onRoles(address token, RoleCheck[] calldata checks) external returns (bytes4);

    /// @notice View twin of `onRoles`: whether the checks would currently pass. MUST NOT be relied on for enforcement.
    function checkRoles(address token, RoleCheck[] calldata checks) external view returns (bool);

    /// @notice The largest figures for which every check in `checks` would pass, were the action scaled down: a limit
    ///         on its `assets` and one on its `shares`, `type(uint256).max` for a figure the checks do not limit. A
    ///         vault's `max*` views scale their capacity to the tighter of the two, then ask `checkRoles` at that
    ///         amount, so a lower limit (a minimum investment) or a refusal is not expressed here but shows there.
    ///         The figures the checks carry are the caller's capacity and may be ignored.
    function maxAllowed(address token, RoleCheck[] calldata checks)
        external
        view
        returns (uint256 maxAssets, uint256 maxShares);
}
