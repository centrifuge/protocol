// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MultiRequestTargets} from "./MultiRequestTargets.sol";

import {d18} from "../../../../src/misc/types/D18.sol";

import {IAsyncVault} from "../../../../src/vaults/interfaces/IAsyncVault.sol";

import {OpType} from "../BeforeAfter.sol";

/// @notice Two or three different investors contribute to ONE window bucket of a shared-window vault (the per-period
///         vaults 1 and 4), the bucket is flushed, the hub settles it as a whole in one or more fills, a fill and a
///         cancellation, or a cancellation, the contributors fold in an order the seed picks (some by a keeper, some
///         left to their claim, some between the fills) and everyone claims in full.
/// @dev    `BucketLib` settles a contributor's slice as `floor(bucket amount * contributed / total)` of the CUMULATIVE
///         settled amount (invariant 2), once per leg and per kind, and the dust a floor leaves stays in the escrow.
///         So, whatever order and however often the contributors fold, a contributor's credit is the closed form
///         `floor(output * contributed / total)`, with `output` the sum of the fills' outputs each at its own price
///         (what `_checkFillPrice` pins the bucket to), and a cancellation refunds `floor(cancelled * contributed /
///         total)` on the opposite side. The credit unit is the one the ledger is gated on (shares for a deposit,
///         assets for a redemption), so the unit that is dropped when it floors to zero cannot make it differ. Sums
///         follow: the credits add up to at most the output and fall short by less than the number of contributors
///         (the fractional parts of the slices add up to a whole number below that count), and the dust stays with the
///         pool. The single-investor conservation cycles never see a slice: every figure there is exact.
///         Whatever precondition is not met (a membership that lapsed, a fill the hub refuses, an escrow reserved past
///         its balance, a contributor with a position already, a window that did not close for the batch) leaves the
///         cycle unchecked rather than failed.
abstract contract ProRataTargets is MultiRequestTargets {
    uint256 internal constant MAX_CONTRIBUTORS = 3;

    /// @dev What a cycle keeps, in memory to stay clear of the stack limit.
    struct Shared {
        IAsyncVault vault;
        uint8 v;
        bool isDeposit;
        bool hasRoute;
        bool moves;
        uint256 requestId;
        uint96 localId;
        uint256 seed;
        uint256 n;
        address[3] who;
        uint256[3] amount;
        uint256 total;
        /// @dev Cumulative, in the bucket's unit: what the fills took, what the cancellations retired, and what the
        ///      fills made at their own prices (shares for a deposit, assets for a redemption).
        uint256 filled;
        uint256 cancelled;
        uint256 output;
        uint256[3] shares0;
        uint256[3] assets0;
        uint256 escrowShares0;
        uint256 escrowAssets0;
        uint256 supply0;
        uint256 outsiderShares0;
        uint256 outsiderAssets0;
    }

    /// @dev Constant prices.
    function flow_sharedProRata(
        uint256 actorSeed,
        uint256 vaultSeed,
        uint256 amountSeed,
        uint256 fillSeed,
        bool isDeposit
    ) public updateGhosts(OpType.MANAGER) {
        if (_sharedProRata(actorSeed, vaultSeed, amountSeed, fillSeed, isDeposit, false)) {
            _ok("flow_sharedProRata");
        }
    }

    /// @dev The share price moves before every fill, so each fill has a price of its own and the credit is the slice of
    ///      the sum of what they made. Not under `updateGhosts`: the price move is a `PRICE` operation.
    function flow_sharedProRataAcrossPrice(
        uint256 actorSeed,
        uint256 vaultSeed,
        uint256 amountSeed,
        uint256 fillSeed,
        bool isDeposit
    ) public {
        if (_sharedProRata(actorSeed, vaultSeed, amountSeed, fillSeed, isDeposit, true)) {
            _ok("flow_sharedProRataAcrossPrice");
        }
    }

    function _sharedProRata(
        uint256 actorSeed,
        uint256 vaultSeed,
        uint256 amountSeed,
        uint256 fillSeed,
        bool isDeposit,
        bool moves
    ) internal returns (bool) {
        Shared memory s;
        // The actor picks add to the seed, so a seed at the top of the range is kept clear of the overflow
        actorSeed %= 2 ** 128;
        s.seed = fillSeed;
        s.isDeposit = isDeposit;
        s.moves = moves;
        if (!_sharedOpen(s, actorSeed, vaultSeed, amountSeed)) return false;
        if (!_sharedSettle(s)) return false;
        _sharedFold(s, s.seed / 7);
        _sharedViews(s, true);
        if (!_sharedClaim(s)) return false;
        _sharedFinish(s);
        return true;
    }

    //----------------------------------------------------------------------------------------------
    // Requests
    //----------------------------------------------------------------------------------------------

    /// @dev Picks the contributors, which all start clean in the vault, and makes their requests into one window, then
    ///      closes the window and flushes the whole bucket.
    function _sharedOpen(Shared memory s, uint256 actorSeed, uint256 vaultSeed, uint256 amountSeed)
        internal
        returns (bool)
    {
        s.v = vaultSeed % 2 == 0 ? 1 : 4;
        s.vault = vaults[s.v];
        if (_overReserved() || !_pricesLive() || !_sharedFillBuys(s.isDeposit)) return false;
        uint256 want = 2 + amountSeed / 8 % (MAX_CONTRIBUTORS - 1);
        for (uint256 i; i < actors.length && s.n < want; i++) {
            address a = actors[(actorSeed + i) % actors.length];
            uint256 balance = s.isDeposit ? usdc.balanceOf(a) : shareA.balanceOf(a);
            if (frozen[a] || !_healthy(s.vault, a) || _hasPositionIn(s.vault, a) || balance < _dust(s.isDeposit)) {
                continue;
            }
            s.who[s.n++] = a;
        }
        if (s.n < 2) return false;
        s.hasRoute = address(s.vault.liquidityRoute()) != address(0);
        _sharedStart(s);
        if (!_sharedRequests(s, amountSeed)) return false;

        Req memory r = Req(s.v, s.requestId, s.isDeposit);
        // The window closes for the batch, every contributor's amount is in it and all of it is queued
        if (s.vault.bucket(s.localId).total != s.total || s.vault.bucket(s.localId).queued != s.total) return false;
        return _flushQueued(r) && _outstanding(r) == s.total;
    }

    /// @dev Amounts: random, all equal, or one of them a few units above the dust against larger ones, which is where
    ///      a floor takes the largest share of a slice.
    function _sharedRequests(Shared memory s, uint256 amountSeed) internal returns (bool) {
        uint128 dust = _dust(s.isDeposit);
        uint256 cap = _sharedCap(s);
        uint256 common = cap;
        for (uint256 i; i < s.n; i++) {
            uint256 b = _min(s.isDeposit ? usdc.balanceOf(s.who[i]) : shareA.balanceOf(s.who[i]), cap);
            common = common < b ? common : b;
        }
        if (common < dust) return false;
        common = between(amountSeed / 4, dust, common);
        for (uint256 i; i < s.n; i++) {
            if (!_sharedRequest(s, i, amountSeed, common, cap)) return false;
        }
        return true;
    }

    function _sharedRequest(Shared memory s, uint256 i, uint256 amountSeed, uint256 common, uint256 cap)
        internal
        returns (bool)
    {
        address a = s.who[i];
        uint256 w = uint256(keccak256(abi.encode(amountSeed, i)));
        uint256 amount = amountSeed % 4 == 1
            ? common
            : between(w, _dust(s.isDeposit), _min(s.isDeposit ? usdc.balanceOf(a) : shareA.balanceOf(a), cap));
        if (amountSeed % 4 >= 2 && i == amountSeed / 16 % s.n) amount = _dust(s.isDeposit) + w % 7;
        (bool requested, uint256 id) =
            s.isDeposit ? _requestDeposit(a, a, s.v, amount) : _requestRedeem(a, a, s.v, amount);
        if (!requested) return false;
        // One window: a request that opened another (time moved under it) is not one bucket
        if (i == 0) (s.requestId, s.localId) = (id, uint96(id));
        else if (id != s.requestId) return false;
        if (s.vault.contribution(s.localId, a).amount != amount) return false;
        s.amount[i] = amount;
        s.total += amount;
        return true;
    }

    /// @dev The most one contributor requests: for a redemption, the shares the escrow's assets pay for with room for
    ///      every contributor twice over, since the hub refuses a fill the pool cannot pay and the cycle would end
    ///      unchecked. A deposit is bounded by the balance alone.
    function _sharedCap(Shared memory s) internal view returns (uint256) {
        if (s.isDeposit) return type(uint256).max;
        uint128 ref = uint128(1e24);
        uint256 out = _fillOutput(false, ref);
        if (out == 0) return 0;
        return usdc.balanceOf(address(_escrow(poolA))) * ref / out / (2 * s.n);
    }

    /// @dev Whether the smallest fill a cycle makes converts to something at the hub's prices and the fee, which the
    ///      OrderBook refuses otherwise.
    function _sharedFillBuys(bool isDeposit) internal view returns (bool) {
        return isDeposit ? _fillBuysShares(_dust(true)) : _fillOutput(false, _dust(false)) != 0;
    }

    /// @dev What the cycle is compared against: the contributors' balances, the escrow, the supply, and everything
    ///      else the vault operations must not move.
    function _sharedStart(Shared memory s) internal view {
        address escrow = address(_escrow(poolA));
        for (uint256 i; i < s.n; i++) {
            s.shares0[i] = shareA.balanceOf(s.who[i]);
            s.assets0[i] = usdc.balanceOf(s.who[i]);
        }
        s.escrowShares0 = shareA.balanceOf(escrow);
        s.escrowAssets0 = usdc.balanceOf(escrow);
        s.supply0 = shareA.totalSupply();
        (s.outsiderShares0, s.outsiderAssets0) = _outsiders(s);
    }

    /// @dev What the accounts outside the cycle hold: every bystander of the vault operations except the contributors.
    function _outsiders(Shared memory s) internal view returns (uint256 sharesHeld, uint256 assetsHeld) {
        (sharesHeld, assetsHeld) = _bystanders(address(0));
        for (uint256 i; i < s.n; i++) {
            sharesHeld -= shareA.balanceOf(s.who[i]);
            assetsHeld -= usdc.balanceOf(s.who[i]);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Settlement
    //----------------------------------------------------------------------------------------------

    /// @dev 0: one fill of the whole bucket. 1: a part, then the rest. 2: a part, then a cancellation of the rest. 3: a
    ///      cancellation of the whole. After a part, the views are held to the closed form and some contributors fold,
    ///      so the second settlement lands on positions at different stages.
    function _sharedSettle(Shared memory s) internal returns (bool) {
        uint128 dust = _dust(s.isDeposit);
        uint256 mode = s.seed % 4;
        if ((mode == 1 || mode == 2) && s.total < 2 * dust) mode = 0;
        if (mode == 3) return _sharedCancel(s, s.total) && _sharedSettled(s);
        if (mode == 0) return _sharedFill(s, s.total) && _sharedSettled(s);

        uint256 first = between(s.seed / 4, dust, s.total - dust);
        if (!_sharedFill(s, first)) return false;
        _sharedViews(s, false);
        _sharedFold(s, s.seed / 3);
        _sharedViews(s, false);
        uint256 rest = s.total - first;
        if (mode == 1 ? !_sharedFill(s, rest) : !_sharedCancel(s, rest)) return false;
        return _sharedSettled(s);
    }

    function _sharedSettled(Shared memory s) internal pure returns (bool) {
        return s.filled + s.cancelled == s.total;
    }

    /// @dev A fill at the price of the moment, which moves before it when the cycle moves prices. What it makes is read
    ///      at that price, right after, before anything moves it.
    function _sharedFill(Shared memory s, uint256 fill) internal returns (bool) {
        if (s.moves) {
            uint256 w = uint256(keccak256(abi.encode(s.seed, fill)));
            _pushPrices(poolA, scA, d18(uint128(between(w, 5e17, 4e18))));
        }
        Req memory r = Req(s.v, s.requestId, s.isDeposit);
        if (!_pricesLive() || !_fulfill(r, uint128(fill))) return false;
        s.filled += fill;
        s.output += _fillOutput(s.isDeposit, uint128(fill));
        return true;
    }

    function _sharedCancel(Shared memory s, uint256 gross) internal returns (bool) {
        if (!_cancel(Req(s.v, s.requestId, s.isDeposit), uint128(gross))) return false;
        s.cancelled += gross;
        return true;
    }

    /// @dev The contributors the seed picks, in the order it picks, are folded by a keeper; the rest wait for their claim
    ///      (or the next fold). The views do not depend on which.
    function _sharedFold(Shared memory s, uint256 seed) internal {
        for (uint256 j; j < s.n; j++) {
            uint256 i = _sharedIndex(s, seed, seed / 5 % 2 == 1, j);
            if ((seed >> (11 + i)) % 2 == 0 || s.vault.contribution(s.localId, s.who[i]).amount == 0) continue;
            _foldOne(s.v, s.localId, s.who[i]);
        }
    }

    function _sharedIndex(Shared memory s, uint256 start, bool reversed, uint256 j) internal pure returns (uint256) {
        return reversed ? (start + s.n - j % s.n) % s.n : (start + j) % s.n;
    }

    //----------------------------------------------------------------------------------------------
    // Checks
    //----------------------------------------------------------------------------------------------

    /// @dev A contributor's slice of a cumulative amount `x`: floored, as `BucketLib` floors it.
    function _slice(Shared memory s, uint256 x, uint256 i) internal pure returns (uint256) {
        return x * s.amount[i] / s.total;
    }

    /// @dev What each contributor can claim, folded or not, against the closed form of the cumulative settlement: the
    ///      credit is the floor of its slice of everything the fills made, the refund the floor of its slice of
    ///      everything cancelled, and what it still has pending is its contribution less the settled slices (nothing
    ///      once the hub has answered the whole bucket). Whatever the order of the folds and however many fills there
    ///      were, the answer is the same.
    function _sharedViews(Shared memory s, bool done) internal {
        for (uint256 i; i < s.n; i++) {
            address a = s.who[i];
            uint256 credit = _slice(s, s.output, i);
            uint256 refund = _slice(s, s.cancelled, i);
            eq(
                s.vault.claimableMint(a),
                s.isDeposit ? credit : refund,
                "a shared window's claimable shares are not the contributor's slice"
            );
            eq(
                s.vault.claimableWithdraw(a),
                s.isDeposit ? refund : credit,
                "a shared window's claimable assets are not the contributor's slice"
            );
            uint256 pending = s.isDeposit ? s.vault.pendingDepositRequest(0, a) : s.vault.pendingRedeemRequest(0, a);
            uint256 expected = done ? 0 : s.amount[i] - _slice(s, s.filled, i) - _slice(s, s.cancelled, i);
            eq(pending, expected, "a shared window's pending is not the contributor's unsettled slice");
        }
    }

    //----------------------------------------------------------------------------------------------
    // Claims
    //----------------------------------------------------------------------------------------------

    /// @dev Everyone claims in full, in an order other than the folds', each checked against the closed form and its own
    ///      balances. A membership that lapsed, or an escrow reserved past its balance, leaves the rest unchecked.
    function _sharedClaim(Shared memory s) internal returns (bool) {
        uint256 start = s.seed / 13;
        bool reversed = s.seed / 17 % 2 == 1;
        for (uint256 j; j < s.n; j++) {
            uint256 i = _sharedIndex(s, start, reversed, j);
            address a = s.who[i];
            if (frozen[a] || !_healthy(s.vault, a) || _overReserved()) return false;
            _claimAll(s.vault, a, 1);
            uint256 credit = _slice(s, s.output, i);
            uint256 refund = _slice(s, s.cancelled, i);
            if (s.isDeposit) {
                eq(
                    shareA.balanceOf(a),
                    s.shares0[i] + credit,
                    "a contributor was paid other than its slice of the shares"
                );
                eq(
                    usdc.balanceOf(a) + s.amount[i],
                    s.assets0[i] + refund,
                    "a contributor got back other than its slice"
                );
            } else {
                eq(
                    usdc.balanceOf(a),
                    s.assets0[i] + credit,
                    "a contributor was paid other than its slice of the assets"
                );
                eq(
                    shareA.balanceOf(a) + s.amount[i],
                    s.shares0[i] + refund,
                    "a contributor got back other than its slice"
                );
            }
            t(
                s.vault.claimableMint(a) == 0 && s.vault.claimableWithdraw(a) == 0,
                "a full claim left a shared window's claim behind"
            );
        }
        return true;
    }

    /// @dev The cycle's totals: the credits fall short of what the fills made by less than the contributors there are,
    ///      and the same for the refunds, never above; equal contributions get credits a unit apart at most and a
    ///      larger one never gets less; the dust the floors leave is in the escrow, the supply moved by what was issued
    ///      or revoked, and nobody outside the cycle moved.
    function _sharedFinish(Shared memory s) internal {
        uint256 credits;
        uint256 refunds;
        for (uint256 i; i < s.n; i++) {
            credits += _slice(s, s.output, i);
            refunds += _slice(s, s.cancelled, i);
            for (uint256 k; k < i; k++) {
                _sharedOrdered(s, i, k);
            }
        }
        lte(credits, s.output, "the contributors' credits add up to more than the fills made");
        lt(
            s.output - credits,
            s.n,
            "the contributors' credits fall short of the fills by a unit per contributor or more"
        );
        lte(refunds, s.cancelled, "the contributors' refunds add up to more than was cancelled");
        lt(
            s.cancelled - refunds,
            s.n,
            "the contributors' refunds fall short of the cancellation by a unit per contributor or more"
        );
        _sharedEscrow(s, credits, refunds);
        (uint256 outsiderShares, uint256 outsiderAssets) = _outsiders(s);
        eq(outsiderShares, s.outsiderShares0, "a shared window cycle moved an outsider's shares");
        if (!s.hasRoute) eq(outsiderAssets, s.outsiderAssets0, "a shared window cycle moved an outsider's assets");
    }

    /// @dev Contributors `i` and `k` after their claims: equal contributions are paid within a unit of each other, a
    ///      larger contribution never less than a smaller.
    function _sharedOrdered(Shared memory s, uint256 i, uint256 k) internal {
        uint256 ci = _slice(s, s.output, i);
        uint256 ck = _slice(s, s.output, k);
        uint256 ri = _slice(s, s.cancelled, i);
        uint256 rk = _slice(s, s.cancelled, k);
        if (s.amount[i] == s.amount[k]) {
            lte(ci > ck ? ci - ck : ck - ci, 1, "equal contributions got credits more than a unit apart");
            lte(ri > rk ? ri - rk : rk - ri, 1, "equal contributions got refunds more than a unit apart");
        } else {
            (uint256 big, uint256 small) = s.amount[i] > s.amount[k] ? (i, k) : (k, i);
            gte(_slice(s, s.output, big), _slice(s, s.output, small), "a larger contribution got a smaller credit");
            gte(
                _slice(s, s.cancelled, big), _slice(s, s.cancelled, small), "a larger contribution got a smaller refund"
            );
        }
    }

    /// @dev A deposit sends all it was requested into the escrow's assets and issues the fills' shares to it; the
    ///      credits and refunds leave, the dust of the floors stays. A redemption puts its shares in the escrow, the
    ///      fills revoke theirs, the refunds leave, and the credits are paid out of the escrow's assets.
    function _sharedEscrow(Shared memory s, uint256 credits, uint256 refunds) internal {
        address escrow = address(_escrow(poolA));
        uint256 escrowShares = shareA.balanceOf(escrow);
        uint256 escrowAssets = usdc.balanceOf(escrow);
        if (s.isDeposit) {
            eq(shareA.totalSupply(), s.supply0 + s.output, "a shared deposit issued other than its fills' shares");
            eq(
                escrowShares,
                s.escrowShares0 + s.output - credits,
                "a shared deposit left other than the dust in shares"
            );
            if (!s.hasRoute) {
                eq(escrowAssets, s.escrowAssets0 + s.total - refunds, "the escrow's assets != what the deposit left");
            }
        } else {
            eq(shareA.totalSupply() + s.filled, s.supply0, "a shared redemption revoked other than its fills' shares");
            eq(
                escrowShares,
                s.escrowShares0 + s.cancelled - refunds,
                "a shared redemption left other than the dust in shares"
            );
            if (!s.hasRoute) eq(escrowAssets + credits, s.escrowAssets0, "the escrow's assets != what it paid");
        }
    }
}
