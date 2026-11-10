// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MathLib} from "../../src/misc/libraries/MathLib.sol";

import {BucketLib} from "../../src/vaults/libraries/BucketLib.sol";
import {Bucket, Contribution, InvestmentState} from "../../src/vaults/interfaces/IAsyncVault.sol";

/// @notice One contributor's newly settled slice of a bucket, as a fold applies it.
struct FoldResult {
    uint128 assets;
    uint128 shares;
    uint128 cancelledGross;
    uint128 cancelledNet;
    bool isDeposit;
    bool completed;
}

/// @title  BucketLib reference
/// @notice The pro-rata math recomputed from a `BucketLib.State` independently of the library, for the
///         harnesses: a contributor's settled slices, what a bucket still has outstanding, and a fold that
///         reports the slice it applied.
library BucketReference {
    using BucketLib for BucketLib.State;

    /// @notice A contributor's total settled pro-rata amounts for one bucket (floor rounding).
    function settled(BucketLib.State storage s, uint96 localId, address controller)
        internal
        view
        returns (uint128 assets, uint128 shares, uint128 cancelledGross, uint128 cancelledNet)
    {
        Bucket storage b = s.buckets[localId];
        uint128 contributed = s.contributions[localId][controller].amount;
        if (contributed == 0) return (0, 0, 0, 0);
        uint128 total = b.total;
        assets = _slice(b.fulfilledAssets, contributed, total);
        shares = _slice(b.fulfilledShares, contributed, total);
        cancelledGross = _slice(b.cancelledGross, contributed, total);
        cancelledNet = _slice(b.cancelledNet, contributed, total);
    }

    /// @notice What the hub has not answered yet in a bucket, in its native unit.
    function outstanding(BucketLib.State storage s, uint96 localId) internal view returns (uint128) {
        return outstanding(s.buckets[localId]);
    }

    /// @notice The same for a bucket read through the vault's `bucket` view.
    function outstanding(Bucket memory b) internal pure returns (uint128) {
        return b.total - (b.isDeposit ? b.fulfilledAssets : b.fulfilledShares) - b.cancelledGross;
    }

    /// @notice Folds through `BucketLib.foldInto` and reports the slice the fold applied.
    function fold(BucketLib.State storage s, InvestmentState storage ledger, uint96 localId, address controller)
        internal
        returns (FoldResult memory r)
    {
        Bucket storage b = s.buckets[localId];
        Contribution storage c = s.contributions[localId][controller];
        r.isDeposit = b.isDeposit;
        if (c.amount != 0 && c.foldedSettlements != b.settlements) {
            (uint128 sa, uint128 ss, uint128 sc, uint128 sn) = settled(s, localId, controller);
            r.assets = sa - c.foldedAssets;
            r.shares = ss - c.foldedShares;
            r.cancelledGross = sc - c.foldedCancelledGross;
            r.cancelledNet = sn - c.foldedCancelledNet;
        }
        r.completed = s.foldInto(ledger, localId, controller);
        // A fold deferred for want of room in the ledger changes nothing, so it applied no slice
        bool applied = c.amount == 0 || c.foldedSettlements == b.settlements;
        if (!applied) {
            r.assets = 0;
            r.shares = 0;
            r.cancelledGross = 0;
            r.cancelledNet = 0;
        }
    }

    function _slice(uint128 amount, uint128 contributed, uint128 total) private pure returns (uint128) {
        return MathLib.toUint128(MathLib.mulDiv(amount, contributed, total, MathLib.Rounding.Down));
    }
}
