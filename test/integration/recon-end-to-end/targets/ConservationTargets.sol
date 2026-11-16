// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {FlowTargets} from "./FlowTargets.sol";

import {d18} from "../../../../src/misc/types/D18.sol";

import {IAsyncVault} from "../../../../src/vaults/interfaces/IAsyncVault.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";

/// @notice Value conservation over whole async cycles and over split claims: what an investor takes out is exactly
///         what the settlements made claimable at their prices, nothing is left owed after a full claim, nobody
///         else's balance moves, and claiming in two parts is never better for the investor than claiming once.
/// @dev    The two-sided counterpart to the one-sided credit checks: they bound a credit from above, these pin it.
abstract contract ConservationTargets is FlowTargets {
    struct Split {
        IAsyncVault vault;
        address actor;
        bool isDeposit;
        bool byShares;
        bytes4 selector;
        uint256 first;
        uint256 second;
    }

    /// @dev What a cycle starts from and what its fills settled, kept in memory to stay clear of the stack limit.
    struct ConservedCycle {
        IAsyncVault vault;
        address actor;
        uint8 v;
        uint256 requestId;
        uint256 fillSeed;
        uint128 newPrice;
        bool isDeposit;
        bool hasRoute;
        uint256 requested;
        uint256 filled;
        uint256 output;
        uint256 cancelled;
        uint256 shares0;
        uint256 assets0;
        uint256 escrowShares0;
        uint256 escrowAssets0;
        uint256 supply0;
        uint256 bystanderShares0;
        uint256 bystanderAssets0;
    }

    /// @dev One investor, alone in a bucket, through request, flush, a fill in one or two parts (or a fill and a
    ///      cancellation of the rest) and a full claim, at constant prices.
    function flow_conserved(uint256 actorSeed, uint256 vaultSeed, uint256 amount, uint256 fillSeed, bool isDeposit)
        public
        updateGhosts(OpType.MANAGER)
    {
        if (_conservedCycle(actorSeed, vaultSeed, amount, fillSeed, isDeposit, 0)) _ok("flow_conserved");
    }

    /// @dev The same cycle with the share price moved between a fill and the claim, and between the two fills: a claim
    ///      pays what each fill settled at its own price, whatever the price is by then. Not under `updateGhosts`: the
    ///      price move is a `PRICE` operation, and the deltas checked after a `MANAGER` one hold it to no price change.
    function flow_conservedAcrossPrice(
        uint256 actorSeed,
        uint256 vaultSeed,
        uint256 amount,
        uint256 fillSeed,
        bool isDeposit,
        uint256 price
    ) public {
        uint128 newPrice = uint128(between(price, 5e17, 4e18));
        if (_conservedCycle(actorSeed, vaultSeed, amount, fillSeed, isDeposit, newPrice)) {
            _ok("flow_conservedAcrossPrice");
        }
    }

    /// @dev Claims part of a position, then the rest of the range, against one claim of the whole. The ledger
    ///      converts pro-rata and the remainder goes to the pool, so two claims never pay more shares or assets, nor
    ///      charge less, than one, and lose at most one unit between them. `deposit` and `redeem` round down, `mint`
    ///      and `withdraw` round up; the quotes are the claims (`vault_previewIsTheClaim`).
    function vault_splitClaim(uint256 actorSeed, uint256 vaultSeed, uint256 firstSeed, uint256 secondSeed, uint8 kind)
        public
        updateGhosts(OpType.USER)
    {
        Split memory p;
        p.isDeposit = kind % 2 == 0;
        p.byShares = kind / 2 % 2 == 1;
        uint256 max;
        (p.vault, p.actor, max) = _findClaim(actorSeed, vaultSeed, p.isDeposit, p.byShares);
        if (max < 2 || frozen[p.actor] || !_healthy(p.vault, p.actor) || (!p.isDeposit && _overReserved())) return;
        p.first = between(firstSeed, 1, max - 1);
        p.second = between(secondSeed, 1, max - p.first);
        p.selector = p.isDeposit
            ? (p.byShares ? p.vault.previewMint.selector : p.vault.previewDeposit.selector)
            : (p.byShares ? p.vault.previewRedeem.selector : p.vault.previewWithdraw.selector);
        if (_splitClaim(p)) _ok("vault_splitClaim");
    }

    function _splitClaim(Split memory p) internal returns (bool) {
        (bool wholeQuoted, uint256 whole) = _quoteAs(p.actor, p.vault, p.selector, p.first + p.second);
        (bool firstQuoted, uint256 quoteFirst) = _quoteAs(p.actor, p.vault, p.selector, p.first);
        if (!wholeQuoted || !firstQuoted) return false;
        bool paidOut = p.isDeposit != p.byShares;
        uint256 held = _heldOut(p);
        if (!_claimPart(p.vault, p.actor, p.first, p.byShares, p.isDeposit)) return false;
        // What a claim paid out is read off the balance, not its preview: a claim that rounded differently from
        // its quote must not pass for the quote
        if (paidOut) quoteFirst = _floorSub(_heldOut(p), held);
        (bool secondQuoted, uint256 quoteSecond) = _quoteAs(p.actor, p.vault, p.selector, p.second);
        held = _heldOut(p);
        if (!secondQuoted || !_claimPart(p.vault, p.actor, p.second, p.byShares, p.isDeposit)) return false;
        if (paidOut) quoteSecond = _floorSub(_heldOut(p), held);

        uint256 parts = quoteFirst + quoteSecond;
        if (paidOut) {
            // Paid out: `deposit` shares, `redeem` assets
            t(parts <= whole, "claiming in two parts paid more than claiming once");
            t(whole <= parts + 1, "claiming in two parts lost more than a unit");
        } else {
            // Charged: `mint` assets, `withdraw` shares
            t(parts >= whole, "claiming in two parts charged less than claiming once");
            t(parts <= whole + 1, "claiming in two parts charged more than a unit above claiming once");
        }
        return true;
    }

    /// @dev The balance a paid-out claim raises: shares on `deposit`, assets on `redeem`.
    function _heldOut(Split memory p) internal view returns (uint256) {
        return p.isDeposit ? shareA.balanceOf(p.actor) : usdc.balanceOf(p.actor);
    }

    function _claimPart(IAsyncVault vault, address actor, uint256 amount, bool byShares, bool isDeposit)
        internal
        returns (bool)
    {
        return isDeposit
            ? _claimDeposit(vault, actor, amount, byShares, false)
            : _claimRedeem(vault, actor, amount, byShares, false);
    }

    function _quoteAs(address actor, IAsyncVault vault, bytes4 selector, uint256 amount)
        internal
        returns (bool, uint256)
    {
        vm.prank(actor);
        return _staticQuote(address(vault), selector, amount);
    }

    //----------------------------------------------------------------------------------------------
    // The cycle
    //----------------------------------------------------------------------------------------------

    /// @dev Returns whether the cycle ran to its checks; every precondition that is not met leaves it unchecked
    ///      rather than failed. The investor starts with nothing pending or claimable in the vault and the request
    ///      is alone in its bucket, so every figure below is exact: no pro-rata slice, no rounding dust.
    ///      A vault with a liquidity route may carry released assets off the escrow, so its asset balances are not
    ///      compared.
    function _conservedCycle(
        uint256 actorSeed,
        uint256 vaultSeed,
        uint256 amount,
        uint256 fillSeed,
        bool isDeposit,
        uint128 newPrice
    ) internal returns (bool) {
        ConservedCycle memory c;
        c.isDeposit = isDeposit;
        c.fillSeed = fillSeed;
        c.newPrice = newPrice;
        if (!_conservedOpen(c, actorSeed, vaultSeed, amount)) return false;
        Req memory r = Req(c.v, c.requestId, isDeposit);
        if (!_conservedSettle(c, r)) return false;
        // The cycle moves time (windows, fills), so a membership can lapse after the opening check: a claim the share
        // hook refuses is not one the cycle can be held to
        if (frozen[c.actor] || !_healthy(c.vault, c.actor)) return false;
        _claimAll(c.vault, c.actor, 1);
        if (_overReserved()) return false;
        _conservedFinish(c);
        return true;
    }

    /// @dev Picks the investor, makes the request and flushes it, if the investor starts clean and the request is
    ///      alone in its bucket.
    function _conservedOpen(ConservedCycle memory c, uint256 actorSeed, uint256 vaultSeed, uint256 amount)
        internal
        returns (bool)
    {
        c.v = _vaultIndex(vaultSeed);
        c.vault = vaults[c.v];
        c.actor = c.isDeposit ? _unfrozen(actorSeed) : _liquidHolder(actorSeed);
        if (frozen[c.actor] || !_healthy(c.vault, c.actor) || _overReserved() || _hasPositionIn(c.vault, c.actor)) {
            return false;
        }
        uint256 balance = c.isDeposit ? usdc.balanceOf(c.actor) : shareA.balanceOf(c.actor);
        if (balance < _dust(c.isDeposit)) return false;
        c.requested = between(amount, _dust(c.isDeposit), balance);
        c.hasRoute = address(c.vault.liquidityRoute()) != address(0);
        _conservedStart(c);

        bool requested;
        (requested, c.requestId) = c.isDeposit
            ? _requestDeposit(c.actor, c.actor, c.v, c.requested)
            : _requestRedeem(c.actor, c.actor, c.v, c.requested);
        if (!requested) return false;
        uint96 localId = uint96(c.requestId);
        if (
            c.vault.bucket(localId).total != c.requested || c.vault.contribution(localId, c.actor).amount != c.requested
        ) {
            return false;
        }
        Req memory r = Req(c.v, c.requestId, c.isDeposit);
        return _flushQueued(r) && _outstanding(r) == c.requested;
    }

    /// @dev One fill, in full or in part; the rest, if any, is filled at the same or a moved price, or cancelled.
    function _conservedSettle(ConservedCycle memory c, Req memory r) internal returns (bool) {
        uint256 fillSeed = c.fillSeed;
        uint128 dust = _dust(c.isDeposit);
        uint128 outstanding = uint128(c.requested);
        bool part = fillSeed % 3 == 0 && outstanding >= 2 * dust;
        uint128 first = part ? uint128(between(fillSeed, dust, outstanding - dust)) : outstanding;
        if (!_fulfill(r, first)) return false;
        c.filled = first;
        c.output = _fillOutput(c.isDeposit, first);

        if (c.newPrice != 0) _pushPrices(poolA, scA, d18(c.newPrice));
        uint128 rest = outstanding - first;
        if (rest == 0) return true;
        if (fillSeed % 2 == 0) {
            if (!_fulfill(r, rest)) return false;
            c.filled += rest;
            c.output += _fillOutput(c.isDeposit, rest);
        } else {
            if (!_cancel(r, rest)) return false;
            c.cancelled = rest;
        }
        return true;
    }

    function _hasPositionIn(IAsyncVault vault, address actor) internal view returns (bool) {
        return vault.claimableMint(actor) != 0 || vault.claimableWithdraw(actor) != 0
            || vault.pendingDepositRequest(0, actor) != 0 || vault.pendingRedeemRequest(0, actor) != 0;
    }

    function _conservedStart(ConservedCycle memory c) internal view {
        address escrow = address(_escrow(poolA));
        c.shares0 = shareA.balanceOf(c.actor);
        c.assets0 = usdc.balanceOf(c.actor);
        c.escrowShares0 = shareA.balanceOf(escrow);
        c.escrowAssets0 = usdc.balanceOf(escrow);
        c.supply0 = shareA.totalSupply();
        (c.bystanderShares0, c.bystanderAssets0) = _bystanders(c.actor);
    }

    /// @dev The balances after a full claim against what the fills settled: a deposit pays `requested - cancelled`
    ///      assets for exactly the shares its fills priced, a redemption gives up `requested - cancelled` shares for
    ///      exactly the assets they priced, the escrow holds the counterpart, the supply moved by what was issued or
    ///      revoked, nothing is owed any more, and nobody else's balance moved.
    function _conservedFinish(ConservedCycle memory c) internal {
        address escrow = address(_escrow(poolA));
        uint256 net = c.requested - c.cancelled;
        t(
            c.vault.claimableMint(c.actor) == 0 && c.vault.claimableWithdraw(c.actor) == 0
                && c.vault.claimableDepositRequest(0, c.actor) == 0 && c.vault.claimableRedeemRequest(0, c.actor) == 0,
            "a full claim left a claim behind"
        );
        if (c.isDeposit) {
            eq(shareA.balanceOf(c.actor), c.shares0 + c.output, "a deposit cycle paid other than its fills' shares");
            eq(usdc.balanceOf(c.actor) + net, c.assets0, "a deposit cycle took other than the assets it filled");
            eq(shareA.totalSupply(), c.supply0 + c.output, "a deposit cycle issued other than its fills' shares");
            eq(shareA.balanceOf(escrow), c.escrowShares0, "a deposit cycle left shares in the escrow");
            if (!c.hasRoute) {
                eq(usdc.balanceOf(escrow), c.escrowAssets0 + net, "the escrow's assets != what the deposit left");
            }
        } else {
            eq(shareA.balanceOf(c.actor) + net, c.shares0, "a redeem cycle took other than the shares it filled");
            eq(usdc.balanceOf(c.actor), c.assets0 + c.output, "a redeem cycle paid other than its fills' assets");
            eq(shareA.totalSupply() + c.filled, c.supply0, "a redeem cycle revoked other than the shares it filled");
            eq(shareA.balanceOf(escrow), c.escrowShares0, "a redeem cycle left shares in the escrow");
            if (!c.hasRoute) {
                eq(usdc.balanceOf(escrow) + c.output, c.escrowAssets0, "the escrow's assets != what it paid");
            }
        }
        (uint256 bystanderShares, uint256 bystanderAssets) = _bystanders(c.actor);
        eq(bystanderShares, c.bystanderShares0, "a vault cycle moved a bystander's shares");
        if (!c.hasRoute) eq(bystanderAssets, c.bystanderAssets0, "a vault cycle moved a bystander's assets");
    }
}
