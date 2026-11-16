// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {FoldResult, BucketReference} from "./BucketReference.sol";

import {MathLib} from "../../src/misc/libraries/MathLib.sol";

import {BucketLib} from "../../src/vaults/libraries/BucketLib.sol";
import {Bucket, InvestmentState} from "../../src/vaults/interfaces/IAsyncVault.sol";

import "forge-std/Test.sol";

/// @dev The full library surface over one `State`, with fold credits accumulated per controller the
///      way the vault's claimable ledger would hold them.
contract BucketFuzzHarness {
    using BucketLib for BucketLib.State;
    using BucketReference for BucketLib.State;

    BucketLib.State internal s;
    mapping(address => InvestmentState) internal _ledgers;

    /// @dev Everything folded out to a controller, per leg: what the vault would have credited
    mapping(address => uint256[4]) internal _credited;

    function contribute(uint96 lid, address who, bool isDeposit, uint128 amount) external {
        s.contribute(lid, who, isDeposit, amount, true, 0);
    }

    function flush(uint96 lid) external {
        s.flush(lid);
    }

    function settle(uint96 lid, bool isDeposit, uint128 assets, uint128 shares, uint128 gross, uint128 net) external {
        s.settle(lid, isDeposit, assets, shares, gross, net);
    }

    function fold(uint96 lid, address who) public returns (bool) {
        FoldResult memory r = s.fold(_ledgers[who], lid, who);
        _credited[who][0] += r.assets;
        _credited[who][1] += r.shares;
        _credited[who][2] += r.cancelledGross;
        _credited[who][3] += r.cancelledNet;
        return r.completed;
    }

    /// @dev The vault's transfer: fold the sender, then move the remainder.
    function transfer(uint96 lid, address from, address to) external {
        fold(lid, from);
        s.transfer(lid, from, to);
    }

    function credited(address who) external view returns (uint256[4] memory) {
        return _credited[who];
    }

    function bucket(uint96 lid) external view returns (Bucket memory) {
        return s.buckets[lid];
    }

    function outstanding(uint96 lid) external view returns (uint128) {
        return s.outstanding(lid);
    }

    function amountOf(uint96 lid, address who) external view returns (uint128) {
        return s.contributions[lid][who].amount;
    }

    function pending(uint96 lid, address who) external view returns (uint128) {
        return s.pendingNow(lid, who);
    }
}

/// @dev Stateless properties of `BucketLib` over the full uint128 range: path independence of folding
///      and transfers, and exact conservation across many contributors and settlements.
contract BucketLibFuzzTest is Test {
    uint96 constant LID = 7;

    function _who(uint256 i) internal pure returns (address) {
        return address(uint160(0xC000 + i));
    }

    /// @dev Log-uniform in `[1, max]`: the low byte picks the magnitude.
    function _amount(uint256 seed, uint256 max) internal pure returns (uint128) {
        uint256 ceiling = 10 ** ((seed & 0xff) % 39);
        return uint128(_bound(seed >> 8, 1, ceiling < max ? ceiling : max));
    }

    //----------------------------------------------------------------------------------------------
    // Transfers
    //----------------------------------------------------------------------------------------------

    /// @dev Whether the receiver folds before a stake is transferred to them or only after makes no
    ///      difference to what they are credited, nor to what the sender is: the transfer merges the
    ///      folded snapshots, so whatever was not folded on one side is folded on the other. Run over
    ///      a three-way bucket settled partially before the transfer and again after it.
    function testFuzzTransferThenFoldEqualsFoldThenTransfer(
        uint256[3] memory amountSeeds,
        uint256 fill1Seed,
        uint256 fill2Seed,
        uint256 otherSeed,
        bool isDeposit
    ) public {
        uint128[3] memory amounts;
        uint256 total;
        for (uint256 i; i < 3; i++) {
            amounts[i] = _amount(amountSeeds[i], type(uint128).max / 3);
            total += amounts[i];
        }
        Fills memory f = Fills({
            first: uint128(_bound(fill1Seed, 0, total - 1)),
            second: 0,
            other: _amount(otherSeed, type(uint128).max / 2),
            isDeposit: isDeposit
        });
        f.second = uint128(_bound(fill2Seed, 0, total - f.first));

        BucketFuzzHarness early = _transferWorld(amounts, f, true);
        BucketFuzzHarness late = _transferWorld(amounts, f, false);

        for (uint256 i; i < 2; i++) {
            uint256[4] memory a = early.credited(_who(i));
            uint256[4] memory b = late.credited(_who(i));
            for (uint256 k; k < 4; k++) {
                assertEq(a[k], b[k], "credit depends on when the receiver folded");
            }
        }

        // And the merged stake is credited at least what the two stakes would have been apart.
        uint256[4] memory merged = early.credited(_who(1));
        uint256[4] memory sender = early.credited(_who(0));
        Bucket memory bkt = early.bucket(LID);
        uint256 nativeFilled = isDeposit ? bkt.fulfilledAssets : bkt.fulfilledShares;
        uint256 apart = _slice(nativeFilled, amounts[0], total) + _slice(nativeFilled, amounts[1], total);
        assertGe(merged[isDeposit ? 0 : 1] + sender[isDeposit ? 0 : 1], apart, "merging lost value");
    }

    struct Fills {
        uint128 first;
        uint128 second;
        uint128 other;
        bool isDeposit;
    }

    /// @dev Three contributors, a fill, a transfer from the first to the second, another fill, then the
    ///      receiver folds. `foldEarly` is the only difference: the receiver also folds before.
    function _transferWorld(uint128[3] memory amounts, Fills memory f, bool foldEarly)
        internal
        returns (BucketFuzzHarness h)
    {
        h = new BucketFuzzHarness();
        for (uint256 i; i < 3; i++) {
            h.contribute(LID, _who(i), f.isDeposit, amounts[i]);
        }
        h.flush(LID);
        if (f.first != 0) _fill(h, f.isDeposit, f.first, f.other);
        if (foldEarly) h.fold(LID, _who(1));
        h.transfer(LID, _who(0), _who(1));
        if (f.second != 0) _fill(h, f.isDeposit, f.second, f.other);
        h.fold(LID, _who(1));
    }

    function _slice(uint256 amount, uint256 contributed, uint256 total) internal pure returns (uint256) {
        return MathLib.mulDiv(amount, contributed, total, MathLib.Rounding.Down);
    }

    function _fill(BucketFuzzHarness h, bool isDeposit, uint128 native, uint128 other) internal {
        (uint128 assets, uint128 shares) = isDeposit ? (native, other) : (other, native);
        h.settle(LID, isDeposit, assets, shares, 0, 0);
    }

    //----------------------------------------------------------------------------------------------
    // Conservation
    //----------------------------------------------------------------------------------------------

    struct Round {
        uint128 fill;
        uint128 other;
        uint128 gross;
        uint128 net;
    }

    /// @dev Up to sixteen contributors over the full uint128 range, settled across several rounds of
    ///      fills and fee-bearing cancellations (the last one settling the rest), with every
    ///      contributor folding at an arbitrary subset of the rounds. Each is credited exactly their
    ///      floor slice of the final totals whatever their folding pattern, the sum never exceeds the
    ///      bucket, and the shortfall is at most one unit per contributor.
    function testFuzzManyContributorConservation(
        uint256 seed,
        uint8 nSeed,
        uint8 roundsSeed,
        bool isDeposit,
        uint256 foldMask
    ) public {
        uint256 n = _bound(nSeed, 2, 16);
        uint256 rounds = _bound(roundsSeed, 1, 5);
        BucketFuzzHarness h = new BucketFuzzHarness();

        uint128[] memory amounts = new uint128[](n);
        uint256 total;
        for (uint256 i; i < n; i++) {
            amounts[i] = _amount(uint256(keccak256(abi.encode(seed, "amount", i))), type(uint128).max / n);
            h.contribute(LID, _who(i), isDeposit, amounts[i]);
            total += amounts[i];
        }
        h.flush(LID);

        for (uint256 r; r < rounds; r++) {
            if (h.outstanding(LID) == 0) break;
            Round memory rd = _round(h, isDeposit, uint256(keccak256(abi.encode(seed, "round", r))), r + 1 == rounds);
            (uint128 assets, uint128 shares) = isDeposit ? (rd.fill, rd.other) : (rd.other, rd.fill);
            h.settle(LID, isDeposit, assets, shares, rd.gross, rd.net);
            for (uint256 i; i < n; i++) {
                if ((foldMask >> (r * 16 + i)) & 1 == 1) h.fold(LID, _who(i));
            }
        }
        for (uint256 i; i < n; i++) {
            assertTrue(h.fold(LID, _who(i)), "a spent bucket completes every contribution");
        }

        _assertExactSlices(h, amounts, total);
    }

    function _assertExactSlices(BucketFuzzHarness h, uint128[] memory amounts, uint256 total) internal view {
        Bucket memory b = h.bucket(LID);
        assertEq(h.outstanding(LID), 0, "the last round settled the rest");
        uint256[4] memory bucketLevel =
            [uint256(b.fulfilledAssets), uint256(b.fulfilledShares), uint256(b.cancelledGross), b.cancelledNet];
        uint256[4] memory sum;
        for (uint256 i; i < amounts.length; i++) {
            uint256[4] memory c = h.credited(_who(i));
            for (uint256 k; k < 4; k++) {
                assertEq(c[k], _slice(bucketLevel[k], amounts[i], total), "credit is not the exact floor slice");
                sum[k] += c[k];
            }
        }
        for (uint256 k; k < 4; k++) {
            assertLe(sum[k], bucketLevel[k], "more credited than settled");
            assertGe(sum[k] + amounts.length, bucketLevel[k], "more than one unit of dust per contributor");
        }
    }

    function _round(BucketFuzzHarness h, bool isDeposit, uint256 seed, bool last)
        internal
        view
        returns (Round memory rd)
    {
        Bucket memory b = h.bucket(LID);
        uint128 rest = h.outstanding(LID);
        uint128 portion = last ? rest : uint128(_bound(seed, 0, rest / 2));
        rd.gross = uint128(_bound(seed >> 128, 0, portion));
        rd.fill = portion - rd.gross;
        uint128 otherSoFar = isDeposit ? b.fulfilledShares : b.fulfilledAssets;
        rd.other =
            rd.fill == 0 ? 0 : _amount(uint256(keccak256(abi.encode(seed))), (type(uint128).max - otherSoFar) / 8);
        rd.net = rd.gross - uint128(_bound(seed >> 64, 0, rd.gross / 10));
        if (rd.fill == 0 && rd.gross == 0) {
            // A no-op settlement is still a valid callback: model it as a one-unit cancellation.
            rd.gross = 1;
            rd.net = 1;
        }
    }

    //----------------------------------------------------------------------------------------------
    // Order independence
    //----------------------------------------------------------------------------------------------

    /// @dev Eight fills on either side, applied in two different orders, with one world folding after
    ///      every fill and the other only once at the end: every contributor ends with exactly the same
    ///      credit. The library keeps cumulative bucket totals and derives each slice from them, so
    ///      neither the order of fills nor the folding cadence can move value between contributors.
    function testFuzzEightFillsAreOrderAndCadenceIndependent(uint256 seed, bool isDeposit) public {
        uint128[3] memory amounts;
        uint256 total;
        for (uint256 i; i < 3; i++) {
            amounts[i] = _amount(uint256(keccak256(abi.encode(seed, i))), type(uint128).max / 3);
            total += amounts[i];
        }

        uint128[8] memory fills;
        uint128[8] memory others;
        uint256 left = total;
        for (uint256 k; k < 8; k++) {
            fills[k] = uint128(k == 7 ? left : _bound(uint256(keccak256(abi.encode(seed, "f", k))), 1, left / 2 + 1));
            if (fills[k] > left) fills[k] = uint128(left);
            left -= fills[k];
            others[k] = _amount(uint256(keccak256(abi.encode(seed, "o", k))), type(uint128).max / 8);
        }

        BucketFuzzHarness eager = new BucketFuzzHarness();
        BucketFuzzHarness lazy = new BucketFuzzHarness();
        for (uint256 i; i < 3; i++) {
            eager.contribute(LID, _who(i), isDeposit, amounts[i]);
            lazy.contribute(LID, _who(i), isDeposit, amounts[i]);
        }
        eager.flush(LID);
        lazy.flush(LID);

        uint256 rot = seed % 8;
        for (uint256 k; k < 8; k++) {
            if (fills[k] != 0) _fill(eager, isDeposit, fills[k], others[k]);
            for (uint256 i; i < 3; i++) {
                eager.fold(LID, _who(i));
            }
            // A rotated, reversed order for the lazy world
            uint256 j = 7 - ((k + rot) % 8);
            if (fills[j] != 0) _fill(lazy, isDeposit, fills[j], others[j]);
        }
        for (uint256 i; i < 3; i++) {
            eager.fold(LID, _who(i));
            lazy.fold(LID, _who(i));
            uint256[4] memory a = eager.credited(_who(i));
            uint256[4] memory b = lazy.credited(_who(i));
            for (uint256 k; k < 4; k++) {
                assertEq(a[k], b[k], "credit depends on fill order or folding cadence");
            }
        }
    }
}
