// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {VaultRequestIdLib} from "./VaultRequestIdLib.sol";

import {MathLib} from "../../misc/libraries/MathLib.sol";

import {
    IVaultErrors,
    IVaultEvents,
    Bucket,
    Contribution,
    InvestmentState,
    UnfoldedState
} from "../interfaces/IAsyncVault.sol";

/// @title  Bucket Library
/// @notice The settlement model for every async request: each request is a contribution to a bucket,
///         fulfillments settle bucket-level, and each contributor's pro-rata slice folds into their
///         claimable ledger. Invariants:
///           1. `total` only grows while the bucket is open; after `flush` only its sole owner may add
///              (their ratio stays 1). `settle` requires a flushed bucket.
///           2. A slice is `fulfilled * contributed / total` rounded down; the dust stays in the escrow.
///           3. The folded snapshot never exceeds the settled total (follows from 1).
///           4. A side's `pending` sums each contribution's pending as of its last fold.
///           5. `HorizonLib` holds each of a controller's positions at most once per side.
///           6. `Bucket.settlements` is bumped exactly when a settled entitlement changes, so a
///              contribution whose `foldedSettlements` matches has nothing to fold.
library BucketLib {
    using MathLib for *;

    /// @dev A contribution's settled slice and what is new in it since its last fold.
    struct Slice {
        uint128 settledAssets;
        uint128 settledShares;
        uint128 cancelledGross;
        uint128 cancelledNet;
        uint128 newAssets;
        uint128 newShares;
        uint128 newCancelledGross;
        uint128 newCancelledNet;
    }

    /// @dev A controller's state on one side, in one slot: a fresh position costs one slot here instead of three, and
    ///      a second costs an update. `HorizonLib` owns the two entries, the oldest of the controller's horizon;
    ///      any beyond them are in `HorizonLib.State.more`.
    struct Side {
        /// @dev Every contribution's remainder as of its last fold, summed
        uint128 pending;
        /// @dev The horizon's oldest entry, or zero when it is empty
        uint64 first;
        /// @dev The horizon's second entry, or zero
        uint64 second;
    }

    struct State {
        mapping(uint96 localId => Bucket) buckets;
        mapping(uint96 localId => mapping(address controller => Contribution)) contributions;
        mapping(address controller => mapping(bool isDeposit => Side)) sides;
    }

    //----------------------------------------------------------------------------------------------
    // Settlement
    //----------------------------------------------------------------------------------------------

    /// @notice Adds `amount` to `controller`'s contribution in bucket `localId`. Reverts if the
    ///         bucket is flushed and the controller is not its sole owner, on a side mismatch, or when an unbatched
    ///         request joins a bucket it does not own. A bucket opened unbatched is flushed at once, so it stays
    ///         its controller's alone, which `owner` records. `key` is the request policy's name for the bucket.
    function contribute(
        State storage s,
        uint96 localId,
        address controller,
        bool isDeposit,
        uint128 amount,
        bool batched,
        bytes32 key
    ) internal {
        Bucket storage b = s.buckets[localId];
        Contribution storage c = s.contributions[localId][controller];

        // No `settlements` bump (invariant 6): nothing settles before a flush, and the sole owner's ratio stays 1.
        require(!b.flushed || c.amount == b.total, IVaultErrors.BucketSealed());

        if (b.total == 0) {
            b.isDeposit = isDeposit;
            if (!batched) b.owner = controller;
            emit IVaultEvents.BucketOpened(VaultRequestIdLib.ofThis(localId), isDeposit, key);
        } else {
            require(b.isDeposit == isDeposit && (batched || b.owner == controller), IVaultErrors.RequestIdInUse());
        }

        c.amount += amount;
        b.total += amount;
        b.queued += amount;
        s.sides[controller][isDeposit].pending += amount;
    }

    /// @notice Takes the queued amount for the vault to send to the hub, zeroing it, and marks the bucket flushed
    ///         (closed to new contributors). Repeatable: the sole owner may flush again after extending.
    function flush(State storage s, uint96 localId) internal returns (uint128 amount, bool isDeposit) {
        Bucket storage b = s.buckets[localId];
        amount = b.queued;
        require(amount != 0, IVaultErrors.NoQueuedRequest());
        b.queued = 0;
        b.flushed = true;
        isDeposit = b.isDeposit;
    }

    /// @notice Records a hub fulfillment against the bucket. `isDeposit` must match the bucket's side
    ///         (the caller derives it from the callback type), and the bucket must have been flushed: a
    ///         settlement answers a request that was sent.
    /// @dev Cancellation is distributed pro-rata like a fulfillment: `cancelledGross` retires what is
    ///      outstanding, `cancelledNet` is credited, and the difference is the retained fee. A single
    ///      contributor of a shared bucket cannot be cancelled alone.
    function settle(
        State storage s,
        uint96 localId,
        bool isDeposit,
        uint128 assets,
        uint128 shares,
        uint128 cancelledGross,
        uint128 cancelledNet
    ) internal {
        Bucket storage b = s.buckets[localId];
        require(b.isDeposit == isDeposit && _outstanding(b) != 0, IVaultErrors.NoPendingRequest());
        // Invariant (1): a later contributor growing `total` would make earlier folds underflow.
        require(b.flushed, IVaultErrors.BucketNotFlushed());
        // A non-zero leg against a zero one would retire what is outstanding while crediting nothing.
        require(assets == 0 ? shares == 0 : shares != 0, IVaultErrors.OneSidedFill());

        if (assets != 0) {
            b.fulfilledAssets += assets;
            b.fulfilledShares += shares;
        }
        if (cancelledGross != 0 || cancelledNet != 0) {
            b.cancelledGross += cancelledGross;
            b.cancelledNet += cancelledNet;
        }

        // Invariant (6): the only place a settled entitlement changes, so the only bump.
        b.settlements++;

        // Bounded by what was sent, not `total`: an over-sized callback would draw on another bucket's backing.
        require(
            uint256((isDeposit ? b.fulfilledAssets : b.fulfilledShares)) + b.cancelledGross <= b.total - b.queued,
            IVaultErrors.OverSettled()
        );
    }

    /// @notice Folds a contributor's newly settled slice of bucket `localId` into their claimable `ledger`,
    ///         the one place claimable balances grow, and cleans the contribution up once the bucket is spent.
    ///         A side is gated on its ledger's unit (shares to mint, assets to withdraw): a slice that floors
    ///         to zero in it is dust, as in `HorizonLib.unfolded`. Returns whether the contribution is settled.
    /// @dev    The ledger's counters are `uint128`. A fold whose credit would overflow one is deferred: it changes
    ///         nothing, so the position stays unfolded and keeps counting as pending, and a fold after the ledger is
    ///         claimed down credits it: a claim's while the position is in the controller's horizon, `foldRequest`
    ///         once it has left it. A checked add would instead revert every claim and view of the
    ///         controller, since each folds its whole horizon first, with nothing it could claim to make room.
    function foldInto(State storage s, InvestmentState storage ledger, uint96 localId, address controller)
        internal
        returns (bool completed)
    {
        Bucket storage b = s.buckets[localId];
        Contribution storage c = s.contributions[localId][controller];
        if (c.amount == 0) return true;
        // Invariant (6): an unchanged count means an unchanged entitlement.
        if (c.foldedSettlements == b.settlements) return false;
        Slice memory x = _slice(b, c);
        if (!_fitsLedger(ledger, b.isDeposit, x)) return false;
        if (_outstanding(b) == 0) {
            _closeContribution(s, ledger, localId, controller, b, c, x);
            return true;
        }

        c.foldedSettlements = b.settlements;
        _advance(s, b, c, controller, x);
        bool credited = _credit(ledger, controller, localId, b.isDeposit, x);
        emit IVaultEvents.RequestFolded(
            VaultRequestIdLib.ofThis(localId),
            controller,
            b.isDeposit,
            credited ? x.newAssets : 0,
            credited ? x.newShares : 0,
            x.newCancelledGross,
            x.newCancelledNet,
            _pendingAtFold(b, c),
            false,
            false
        );
        return false;
    }

    /// @notice Reassigns `from`'s entire contribution in bucket `localId` to `to` (ERC-8161). The caller must have
    ///         folded `from` first, so the snapshot moves cleanly, and drops it from `from`'s horizon. A fold that was
    ///         deferred leaves `from`'s settled slice unfolded, and moving it would hand that slice to `to`, so the
    ///         transfer waits until it folds. Returns the amount contributed that moved.
    function transfer(State storage s, uint96 localId, address from, address to) internal returns (uint128 moved) {
        require(from != to && to != address(0), IVaultErrors.InvalidController());
        Bucket storage b = s.buckets[localId];
        Contribution storage src = s.contributions[localId][from];
        Contribution storage dst = s.contributions[localId][to];
        require(src.amount != 0, IVaultErrors.NoContribution());
        require(src.foldedSettlements == b.settlements, IVaultErrors.FoldDeferred());
        moved = src.amount;

        // Remainders add, so the summed snapshots below move exactly this much.
        uint128 pending = _pendingAtFold(b, src);
        s.sides[from][b.isDeposit].pending -= pending;
        s.sides[to][b.isDeposit].pending += pending;

        dst.amount += src.amount;
        dst.foldedAssets += src.foldedAssets;
        dst.foldedShares += src.foldedShares;
        dst.foldedCancelledNet += src.foldedCancelledNet;
        dst.foldedCancelledGross += src.foldedCancelledGross;

        // The summed snapshots can undershoot the larger contribution's slice, so re-arm one fold.
        dst.foldedSettlements = 0;
        delete s.contributions[localId][from];
        if (b.owner == from) b.owner = to;
    }

    //----------------------------------------------------------------------------------------------
    // Views
    //----------------------------------------------------------------------------------------------

    /// @notice A controller's pending amount in one bucket as of the current settlements, in its native unit:
    ///         contributed minus the settled portion, zero once the bucket is spent. Counts slices not yet folded.
    function pendingNow(State storage s, uint96 localId, address controller) internal view returns (uint128) {
        Bucket storage b = s.buckets[localId];
        Contribution storage c = s.contributions[localId][controller];
        // Invariant (6): a contributor whose fold is current has its settled slice as its snapshot.
        if (c.foldedSettlements == b.settlements) return _pendingAtFold(b, c);
        (uint128 settledAssets, uint128 settledShares, uint128 cancelledGross,) = _settled(b, c.amount);
        return _pendingAfterSettled(b, c.amount, b.isDeposit ? settledAssets : settledShares, cancelledGross);
    }

    /// @notice A controller's pending amount in one bucket as of its last fold: settled slices not yet folded
    ///         still count as pending.
    function pendingAtFold(State storage s, uint96 localId, address controller) internal view returns (uint128) {
        return _pendingAtFold(s.buckets[localId], s.contributions[localId][controller]);
    }

    /// @notice Adds one horizon entry to `u`: what a fold would credit, gated on the ledger's unit like
    ///         `foldInto`, and the settled part of its pending moved out of the totals. An entry whose credit would
    ///         not fit the ledger on top of what `u` already holds is deferred as the fold defers it: nothing is added
    ///         and all of it is still pending.
    function addUnfolded(
        Bucket storage b,
        Contribution storage c,
        UnfoldedState memory u,
        InvestmentState storage ledger
    ) internal view {
        // Invariant (6): a contributor whose fold is current has nothing unfolded.
        if (c.foldedSettlements == b.settlements) return;

        bool isDeposit = b.isDeposit;
        Slice memory x = _slice(b, c);
        bool fits = isDeposit
            ? _fits(
                true,
                _creditable(true, x.newAssets, x.newShares),
                x,
                uint256(ledger.depositShares) + u.depositShares,
                uint256(ledger.depositAssets) + u.depositAssets,
                uint256(ledger.refundAssets) + u.refundAssets
            )
            : _fits(
                false,
                _creditable(false, x.newAssets, x.newShares),
                x,
                uint256(ledger.redeemAssets) + u.redeemAssets,
                uint256(ledger.redeemShares) + u.redeemShares,
                uint256(ledger.refundShares) + u.refundShares
            );
        if (!fits) return;

        uint128 stillPending =
            _pendingAfterSettled(b, c.amount, isDeposit ? x.settledAssets : x.settledShares, x.cancelledGross);
        uint128 settledPart = _pendingAtFold(b, c) - stillPending;

        bool credited = _creditable(isDeposit, x.newAssets, x.newShares);
        if (isDeposit) {
            if (credited) {
                u.depositShares += x.newShares;
                u.depositAssets += x.newAssets;
            }
            u.depositPending -= settledPart;
            u.refundAssets += x.newCancelledNet;
        } else {
            if (credited) {
                u.redeemShares += x.newShares;
                u.redeemAssets += x.newAssets;
            }
            u.redeemPending -= settledPart;
            u.refundShares += x.newCancelledNet;
        }
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    /// @dev The fold that settles a contribution for good. Its snapshots and fold count would be written and then
    ///      deleted with it, so they are skipped: what it credits is the slice against the snapshots it has.
    function _closeContribution(
        State storage s,
        InvestmentState storage ledger,
        uint96 localId,
        address controller,
        Bucket storage b,
        Contribution storage c,
        Slice memory x
    ) private {
        // The floor-rounding dust a completed contribution leaves behind is no longer pending either.
        s.sides[controller][b.isDeposit].pending -= _pendingAtFold(b, c);
        bool credited = _credit(ledger, controller, localId, b.isDeposit, x);

        // A sole owner's bucket is retired so its id can be reused; a shared one keeps its totals for later folds.
        bool retired = c.amount == b.total;
        emit IVaultEvents.RequestFolded(
            VaultRequestIdLib.ofThis(localId),
            controller,
            b.isDeposit,
            credited ? x.newAssets : 0,
            credited ? x.newShares : 0,
            x.newCancelledGross,
            x.newCancelledNet,
            0,
            true,
            retired
        );
        if (retired) delete s.buckets[localId];
        delete s.contributions[localId][controller];
    }

    /// @dev What a fold would credit now: the settled slice of a contribution less its folded snapshot, with the
    ///      slice itself so a fold can move the snapshot up to it. Cannot underflow (invariant 3). The
    ///      cancellation part is skipped without a cancellation, which leaves both snapshots at zero; both are
    ///      checked, since a gross flooring to zero can carry a net of one.
    function _slice(Bucket storage b, Contribution storage c) private view returns (Slice memory x) {
        (x.settledAssets, x.settledShares, x.cancelledGross, x.cancelledNet) = _settled(b, c.amount);
        x.newAssets = x.settledAssets - c.foldedAssets;
        x.newShares = x.settledShares - c.foldedShares;
        if (x.cancelledGross != 0 || x.cancelledNet != 0) {
            x.newCancelledNet = x.cancelledNet - c.foldedCancelledNet;
            x.newCancelledGross = x.cancelledGross - c.foldedCancelledGross;
        }
    }

    /// @dev Moves the contribution's folded snapshot up to its settled slice and its pending total down by
    ///      as much.
    function _advance(State storage s, Bucket storage b, Contribution storage c, address controller, Slice memory x)
        private
    {
        uint128 remainder = _pendingAtFold(b, c);
        c.foldedAssets = x.settledAssets;
        c.foldedShares = x.settledShares;
        if (x.cancelledGross != 0 || x.cancelledNet != 0) {
            c.foldedCancelledNet = x.cancelledNet;
            c.foldedCancelledGross = x.cancelledGross;
        }
        s.sides[controller][b.isDeposit].pending -= remainder - _pendingAtFold(b, c);
    }

    /// @dev Whether crediting `x` stays inside the ledger's `uint128` counters, as the fold would apply it.
    function _fitsLedger(InvestmentState storage ledger, bool isDeposit, Slice memory x) private view returns (bool) {
        bool credited = _creditable(isDeposit, x.newAssets, x.newShares);
        return isDeposit
            ? _fits(true, credited, x, ledger.depositShares, ledger.depositAssets, ledger.refundAssets)
            : _fits(false, credited, x, ledger.redeemAssets, ledger.redeemShares, ledger.refundShares);
    }

    /// @dev The counters a credit touches, as they stand: the two of the filled leg (deposit: shares to mint then
    ///      assets they were bought with; redeem: assets to withdraw then shares they were paid for) and the refund
    ///      one. The fold and the views share this one answer, so they defer the same entries.
    function _fits(bool isDeposit, bool credited, Slice memory x, uint256 first, uint256 second, uint256 refund)
        private
        pure
        returns (bool)
    {
        uint256 max = type(uint128).max;
        if (credited) {
            if (first + (isDeposit ? x.newShares : x.newAssets) > max) return false;
            if (second + (isDeposit ? x.newAssets : x.newShares) > max) return false;
        }
        return x.newCancelledNet == 0 || refund + x.newCancelledNet <= max;
    }

    /// @dev A side is gated on its ledger's unit (shares to mint, assets to withdraw): a slice that floors to
    ///      zero in it is dust. The fold and the views agree through this one answer.
    function _creditable(bool isDeposit, uint128 assets, uint128 shares) private pure returns (bool) {
        return isDeposit ? shares > 0 : assets > 0;
    }

    /// @dev Credits `x` to the ledger and returns whether its filled leg counted: in the unit the ledger does not keep,
    ///      a slice that floors to dust credits nothing.
    function _credit(InvestmentState storage ledger, address controller, uint96 localId, bool isDeposit, Slice memory x)
        private
        returns (bool credited)
    {
        uint256 requestId = VaultRequestIdLib.ofThis(localId);
        credited = _creditable(isDeposit, x.newAssets, x.newShares);
        if (isDeposit) {
            if (credited) {
                ledger.depositShares += x.newShares;
                ledger.depositAssets += x.newAssets;
                emit IVaultEvents.DepositClaimable(requestId, controller, x.newAssets, x.newShares);
            }
            if (x.newCancelledNet > 0) {
                ledger.refundAssets += x.newCancelledNet;
                emit IVaultEvents.CancelDepositClaimable(requestId, controller, x.newCancelledNet);
            }
        } else {
            if (credited) {
                ledger.redeemAssets += x.newAssets;
                ledger.redeemShares += x.newShares;
                emit IVaultEvents.RedeemClaimable(requestId, controller, x.newAssets, x.newShares);
            }
            if (x.newCancelledNet > 0) {
                ledger.refundShares += x.newCancelledNet;
                emit IVaultEvents.CancelRedeemClaimable(requestId, controller, x.newCancelledNet);
            }
        }
    }

    /// @dev A contribution's pending as of its last fold: contributed less its folded settlements.
    function _pendingAtFold(Bucket storage b, Contribution storage c) private view returns (uint128) {
        uint128 settled = (b.isDeposit ? c.foldedAssets : c.foldedShares) + c.foldedCancelledGross;
        return MathLib.saturatingSub(c.amount, settled);
    }

    /// @dev What of `contributed` is still pending given its settled native and gross cancelled slices.
    ///      Zero in a spent bucket: what the floors left behind is dust, not pending, or a spent request
    ///      would close its contributors' instant lane for good.
    function _pendingAfterSettled(Bucket storage b, uint128 contributed, uint128 settledNative, uint128 cancelledGross)
        private
        view
        returns (uint128)
    {
        if (_outstanding(b) == 0) return 0;
        return MathLib.saturatingSub(contributed, settledNative + cancelledGross);
    }

    /// @dev What the hub has not answered yet, in the bucket's native unit, queued top-ups included.
    function _outstanding(Bucket storage b) private view returns (uint128) {
        return b.total - (b.isDeposit ? b.fulfilledAssets : b.fulfilledShares) - b.cancelledGross;
    }

    function _settled(Bucket storage b, uint128 contributed)
        private
        view
        returns (uint128 assets, uint128 shares, uint128 cancelledGross, uint128 cancelledNet)
    {
        if (contributed == 0) return (0, 0, 0, 0);

        // A sole contributor takes the bucket whole, the common case.
        uint128 total = b.total;
        if (contributed == total) return (b.fulfilledAssets, b.fulfilledShares, b.cancelledGross, b.cancelledNet);

        // Each slice floors (invariant 2), and the dust stays in the escrow.
        assets = b.fulfilledAssets.fractionOf(contributed, total, MathLib.Rounding.Down).toUint128();
        shares = b.fulfilledShares.fractionOf(contributed, total, MathLib.Rounding.Down).toUint128();
        cancelledGross = b.cancelledGross.fractionOf(contributed, total, MathLib.Rounding.Down).toUint128();
        cancelledNet = b.cancelledNet.fractionOf(contributed, total, MathLib.Rounding.Down).toUint128();
    }
}
