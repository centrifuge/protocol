// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BucketLib} from "./BucketLib.sol";
import {VaultRequestIdLib} from "./VaultRequestIdLib.sol";

import {InvestmentState, UnfoldedState, IVaultEvents} from "../interfaces/IAsyncVault.sol";

/// @title  Horizon Library
/// @notice The short list of a controller's latest positions per side that every claim folds first, so a claim costs
///         the same however many positions the controller holds. A position outside it folds at settlement if
///         unbatched, and a batch waits for `foldRequest`. The rules are in `src/vaults/ARCHITECTURE.md`.
///         Invariant (5): a position is in a horizon at most once per side.
library HorizonLib {
    using BucketLib for BucketLib.State;

    /// @dev The horizon's entries after the first two, oldest first, four to a slot. The two before them sit in the
    ///      controller's `BucketLib.Side`, so a horizon of two never touches this. An entry is never zero, so what
    ///      follows the last one is.
    struct State {
        mapping(address controller => mapping(bool isDeposit => mapping(uint256 slot => uint256))) more;
    }

    //----------------------------------------------------------------------------------------------
    // Horizon updates
    //----------------------------------------------------------------------------------------------

    /// @notice Folds both sides of the controller's horizon into `ledger`, dropping completed entries.
    function fold(State storage h, BucketLib.State storage s, InvestmentState storage ledger, address controller)
        internal
    {
        _foldSide(h, s, ledger, controller, true);
        _foldSide(h, s, ledger, controller, false);
    }

    /// @notice Adds a position, unless it is already tracked. A full horizon makes way for the controller's own
    ///         position by its oldest entry, which is folded if settled and dropped either way. A position that is
    ///         not `own` (a gift) only takes a free slot. `limit` is the horizon for an own position and the slots a
    ///         gift may fill for a gift, at least 1 either way. One left out folds as it settles if unbatched, and a
    ///         batch waits for `foldRequest`.
    function add(
        State storage h,
        BucketLib.State storage s,
        InvestmentState storage ledger,
        address controller,
        uint96 localId,
        bool isDeposit,
        bool own,
        uint256 limit
    ) internal {
        uint96[] memory ids = entries(h, s, controller, isDeposit);
        uint256 length = ids.length;
        for (uint256 i; i < length; i++) {
            if (ids[i] == localId) return;
        }

        if (!own && length >= limit) {
            emit IVaultEvents.OutsideHorizon(VaultRequestIdLib.ofThis(localId), controller, isDeposit);
            return;
        }
        while (length >= limit) {
            uint96 evicted = ids[0];
            // A stale entry, its id reused on the other side, is dropped unfolded as in a claim.
            if (s.buckets[evicted].isDeposit == isDeposit && !s.foldInto(ledger, evicted, controller)) {
                emit IVaultEvents.OutsideHorizon(VaultRequestIdLib.ofThis(evicted), controller, isDeposit);
            }
            length = _drop(ids, 0, length);
        }

        uint96[] memory grown = new uint96[](length + 1);
        for (uint256 i; i < length; i++) {
            grown[i] = ids[i];
        }
        grown[length] = localId;
        _store(h, s, controller, isDeposit, grown, length + 1, ids.length);
    }

    /// @notice Drops a position from the horizon, keeping the order of the rest.
    function remove(State storage h, BucketLib.State storage s, address controller, uint96 localId, bool isDeposit)
        internal
    {
        uint96[] memory ids = entries(h, s, controller, isDeposit);
        uint256 length = ids.length;
        for (uint256 i; i < length; i++) {
            if (ids[i] != localId) continue;
            length = _drop(ids, i, length);
            _store(h, s, controller, isDeposit, ids, length, ids.length);
            return;
        }
    }

    //----------------------------------------------------------------------------------------------
    // Views
    //----------------------------------------------------------------------------------------------

    /// @notice Whether `localId` is in the controller's horizon on that side.
    function contains(State storage h, BucketLib.State storage s, address controller, uint96 localId, bool isDeposit)
        internal
        view
        returns (bool)
    {
        uint96[] memory ids = entries(h, s, controller, isDeposit);
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == localId) return true;
        }
        return false;
    }

    /// @notice The controller's horizon on that side, oldest first.
    /// @dev    Two entries from the controller's slot, the rest from `more`, which a horizon of two never reads. The
    ///         end is the first zero entry.
    function entries(State storage h, BucketLib.State storage s, address controller, bool isDeposit)
        internal
        view
        returns (uint96[] memory ids)
    {
        BucketLib.Side memory side = s.sides[controller][isDeposit];
        if (side.first == 0) return new uint96[](0);
        if (side.second == 0) {
            ids = new uint96[](1);
            ids[0] = side.first;
            return ids;
        }

        mapping(uint256 => uint256) storage more = h.more[controller][isDeposit];
        uint256 n = 2;
        for (uint256 slot;; slot++) {
            uint256 packed = more[slot];
            uint256 used;
            while (used < 4 && uint64(packed >> (64 * used)) != 0) {
                used++;
            }
            n += used;
            if (used < 4) break;
        }

        ids = new uint96[](n);
        ids[0] = side.first;
        ids[1] = side.second;
        for (uint256 i = 2; i < n; i++) {
            uint256 k = i - 2;
            ids[i] = uint64(more[k / 4] >> (64 * (k % 4)));
        }
    }

    /// @notice A position's pending amount as the views report it: settled slices count as pending until folded,
    ///         except in the horizon, whose unfolded slices claims include.
    function pendingReported(State storage h, BucketLib.State storage s, uint96 localId, address controller)
        internal
        view
        returns (uint128)
    {
        if (contains(h, s, controller, localId, s.buckets[localId].isDeposit)) {
            return s.pendingNow(localId, controller);
        }
        return s.pendingAtFold(localId, controller);
    }

    /// @notice The horizon's settled-but-unfolded claimable entitlements per direction, and the pending totals
    ///         with the horizon's settled slices taken out (they are claimable, not pending).
    function unfolded(State storage h, BucketLib.State storage s, InvestmentState storage ledger, address controller)
        internal
        view
        returns (UnfoldedState memory u)
    {
        u.depositPending = s.sides[controller][true].pending;
        u.redeemPending = s.sides[controller][false].pending;
        _addSide(h, s, ledger, controller, true, u);
        _addSide(h, s, ledger, controller, false, u);
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    function _foldSide(
        State storage h,
        BucketLib.State storage s,
        InvestmentState storage ledger,
        address controller,
        bool isDeposit
    ) private {
        uint96[] memory ids = entries(h, s, controller, isDeposit);
        uint256 length = ids.length;
        uint256 kept;
        for (uint256 i; i < length; i++) {
            uint96 localId = ids[i];
            // An entry whose id a policy has since reused on the other side is stale here: drop it.
            if (s.buckets[localId].isDeposit != isDeposit) continue;
            if (s.foldInto(ledger, localId, controller)) continue;
            ids[kept++] = localId;
        }
        if (kept != length) _store(h, s, controller, isDeposit, ids, kept, length);
    }

    function _addSide(
        State storage h,
        BucketLib.State storage s,
        InvestmentState storage ledger,
        address controller,
        bool isDeposit,
        UnfoldedState memory u
    ) private view {
        uint96[] memory ids = entries(h, s, controller, isDeposit);
        for (uint256 i; i < ids.length; i++) {
            uint96 localId = ids[i];
            if (s.buckets[localId].isDeposit != isDeposit) continue;
            BucketLib.addUnfolded(s.buckets[localId], s.contributions[localId][controller], u, ledger);
        }
    }

    /// @dev Writes `ids[0 .. length)` back over what held `before` entries, touching only what differs: a horizon
    ///      that stays within two entries writes the controller's slot alone, and never reads `more`.
    function _store(
        State storage h,
        BucketLib.State storage s,
        address controller,
        bool isDeposit,
        uint96[] memory ids,
        uint256 length,
        uint256 before
    ) private {
        BucketLib.Side storage side = s.sides[controller][isDeposit];
        uint64 first = length > 0 ? uint64(ids[0]) : 0;
        uint64 second = length > 1 ? uint64(ids[1]) : 0;
        if (side.first != first) side.first = first;
        if (side.second != second) side.second = second;
        if (before <= 2 && length <= 2) return;

        mapping(uint256 => uint256) storage more = h.more[controller][isDeposit];
        uint256 slotsAfter = (length + 1) / 4;
        uint256 slotsBefore = (before + 1) / 4;
        for (uint256 j; j < slotsAfter; j++) {
            uint256 packed = _pack(ids, length, j);
            if (more[j] != packed) more[j] = packed;
        }
        for (uint256 j = slotsAfter; j < slotsBefore; j++) {
            delete more[j];
        }
    }

    /// @dev Slot `j` of `more`: the four entries after the first two that it holds, zero past `length`.
    function _pack(uint96[] memory ids, uint256 length, uint256 j) private pure returns (uint256 packed) {
        for (uint256 k; k < 4; k++) {
            uint256 i = 2 + 4 * j + k;
            if (i < length) packed |= uint256(uint64(ids[i])) << (64 * k);
        }
    }

    /// @dev Removes `ids[index]`, shifting the rest left, and returns the new length. The array keeps its size; only
    ///      `[0 .. length)` is meaningful.
    function _drop(uint96[] memory ids, uint256 index, uint256 length) private pure returns (uint256) {
        for (uint256 i = index; i + 1 < length; i++) {
            ids[i] = ids[i + 1];
        }
        ids[length - 1] = 0;
        return length - 1;
    }
}
