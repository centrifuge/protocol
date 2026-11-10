// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BucketReference} from "./BucketReference.sol";

import {MathLib} from "../../src/misc/libraries/MathLib.sol";

import {BucketLib} from "../../src/vaults/libraries/BucketLib.sol";
import {HorizonLib} from "../../src/vaults/libraries/HorizonLib.sol";
import {Bucket, Contribution, InvestmentState, UnfoldedState} from "../../src/vaults/interfaces/IAsyncVault.sol";

import "forge-std/Test.sol";

/// @dev Drives a `BucketLib.State` the way the vault does (own requests enter the horizon, a transfer
///      moves the position out of the sender's and into the receiver's) and carries the
///      pre-short-circuit view math as a reference, so the two can be compared on whatever state the
///      fuzzer reaches.
contract ShortCircuitHarness {
    using BucketLib for BucketLib.State;
    using HorizonLib for HorizonLib.State;
    using BucketReference for BucketLib.State;

    BucketLib.State internal s;
    HorizonLib.State internal h;
    mapping(address => InvestmentState) internal _ledgers;

    function contribute(uint96 localId, address controller, bool isDeposit, uint128 amount) external {
        s.contribute(localId, controller, isDeposit, amount, true, 0);
        _remember(controller, localId, isDeposit);
    }

    /// @dev A horizon wide enough that nothing is evicted, so every position is in it.
    function _remember(address controller, uint96 localId, bool isDeposit) internal {
        if (h.contains(s, controller, localId, isDeposit)) return;
        h.add(s, _ledgers[controller], controller, localId, isDeposit, true, 8);
    }

    function flush(uint96 localId) external {
        s.flush(localId);
    }

    function settle(uint96 localId, bool isDeposit, uint128 assets, uint128 shares, uint128 gross, uint128 net)
        external
    {
        s.settle(localId, isDeposit, assets, shares, gross, net);
    }

    /// @dev `foldRequest`
    function fold(uint96 localId, address controller) external {
        if (s.contributions[localId][controller].amount == 0) return;
        s.foldInto(_ledgers[controller], localId, controller);
    }

    /// @dev `_transferRequest`: fold the sender out, move the remainder between the horizons.
    function transfer(uint96 localId, address from, address to) external {
        bool isDeposit = s.buckets[localId].isDeposit;
        bool completed = s.foldInto(_ledgers[from], localId, from);
        if (completed || s.contributions[localId][from].amount == 0) return;
        s.transfer(localId, from, to);
        h.remove(s, from, localId, isDeposit);
        _remember(to, localId, isDeposit);
    }

    function bucket(uint96 localId) external view returns (Bucket memory) {
        return s.buckets[localId];
    }

    function outstanding(uint96 localId) external view returns (uint128) {
        return s.outstanding(localId);
    }

    function unfolded(address controller) external view returns (UnfoldedState memory) {
        return h.unfolded(s, _ledgers[controller], controller);
    }

    function pending(uint96 localId, address controller) external view returns (uint128) {
        return s.pendingNow(localId, controller);
    }

    /// @dev `pending` before the short-circuit: always derive the settled slice.
    function pendingReference(uint96 localId, address controller) public view returns (uint128) {
        Bucket storage b = s.buckets[localId];
        if (s.outstanding(localId) == 0) return 0;
        uint128 contributed = s.contributions[localId][controller].amount;
        (uint128 assets, uint128 shares, uint128 cancelled,) = s.settled(localId, controller);
        return MathLib.saturatingSub(contributed, (b.isDeposit ? assets : shares) + cancelled);
    }

    /// @dev `unfolded` before the short-circuit: every horizon entry through the full settlement math,
    ///      over a pending total recomputed from `ids`, which must cover every bucket the controller holds.
    function unfoldedReference(address controller, uint96[3] calldata ids)
        external
        view
        returns (UnfoldedState memory u)
    {
        for (uint256 i; i < ids.length; i++) {
            if (s.buckets[ids[i]].isDeposit) u.depositPending += _remainder(ids[i], controller);
            else u.redeemPending += _remainder(ids[i], controller);
        }
        for (uint256 side; side < 2; side++) {
            uint96[] memory recent = h.entries(s, controller, side == 0);
            for (uint256 i; i < recent.length; i++) {
                uint96 localId = recent[i];
                Contribution storage c = s.contributions[localId][controller];
                (uint128 sa, uint128 ss,, uint128 sn) = s.settled(localId, controller);
                uint128 settledPart = _remainder(localId, controller) - pendingReference(localId, controller);
                if (s.buckets[localId].isDeposit) {
                    if (ss != c.foldedShares) {
                        u.depositShares += ss - c.foldedShares;
                        u.depositAssets += sa - c.foldedAssets;
                    }
                    u.depositPending -= settledPart;
                    if (sn != 0) u.refundAssets += sn - c.foldedCancelledNet;
                } else {
                    if (sa != c.foldedAssets) {
                        u.redeemShares += ss - c.foldedShares;
                        u.redeemAssets += sa - c.foldedAssets;
                    }
                    u.redeemPending -= settledPart;
                    if (sn != 0) u.refundShares += sn - c.foldedCancelledNet;
                }
            }
        }
    }

    function _remainder(uint96 localId, address controller) internal view returns (uint128) {
        Contribution storage c = s.contributions[localId][controller];
        uint128 folded = (s.buckets[localId].isDeposit ? c.foldedAssets : c.foldedShares) + c.foldedCancelledGross;
        return c.amount > folded ? c.amount - folded : 0;
    }
}

/// @title  BucketLib short-circuit equivalence
/// @notice `pending` and `unfolded` skip the settlement math for a contribution whose fold is current
///         (invariant 6) and read its pending off the folded snapshot instead. This proves, statelessly
///         over fuzzed histories, that the skip answers exactly what the full computation does: idle and
///         unflushed buckets, partial fills folded and not, a cancellation with a retained fee, a
///         transfer into another controller's horizon, and both sides.
contract BucketLibShortCircuitTest is Test {
    ShortCircuitHarness h;

    uint96 constant SHARED = 1; // deposit bucket, alice + bob
    uint96 constant REDEEM = 2; // redeem bucket, alice alone
    uint96 constant IDLE = 3; // deposit bucket, carol alone, may never flush

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        h = new ShortCircuitHarness();
    }

    struct Amounts {
        uint128 alice;
        uint128 bob;
        uint128 redeem;
        uint128 idle;
    }

    struct Fills {
        uint256 first;
        uint256 second;
        uint256 redeem;
        uint256 gross;
        uint256 net;
        uint256 price;
    }

    function testFuzz_shortCircuitMatchesFullComputation(Amounts memory a, Fills memory f, uint16 flags) public {
        a.alice = uint128(bound(a.alice, 1, 1e30));
        a.bob = uint128(bound(a.bob, 1, 1e30));
        a.redeem = uint128(bound(a.redeem, 1, 1e30));
        a.idle = uint128(bound(a.idle, 1, 1e30));

        h.contribute(SHARED, alice, true, a.alice);
        h.contribute(SHARED, bob, true, a.bob);
        h.contribute(REDEEM, alice, false, a.redeem);
        h.contribute(IDLE, carol, true, a.idle);
        _check();

        if (_bit(flags, 0)) h.flush(SHARED);
        if (_bit(flags, 1)) h.flush(REDEEM);
        if (_bit(flags, 2)) h.flush(IDLE);

        if (_bit(flags, 3)) _fill(SHARED, true, f.first, f.price);
        _check();
        if (_bit(flags, 4)) h.fold(SHARED, alice);
        if (_bit(flags, 5)) h.fold(SHARED, bob);
        _check();

        if (_bit(flags, 6)) _cancel(SHARED, f.gross, f.net);
        if (_bit(flags, 7)) h.fold(SHARED, alice);
        _check();

        if (_bit(flags, 8)) h.transfer(SHARED, alice, carol);
        _check();

        if (_bit(flags, 9)) _fill(REDEEM, false, f.redeem, f.price);
        if (_bit(flags, 10)) h.fold(REDEEM, alice);
        _check();

        if (_bit(flags, 11)) _fill(SHARED, true, f.second, f.price);
        if (_bit(flags, 12)) h.fold(SHARED, carol);
        if (_bit(flags, 13)) h.fold(SHARED, bob);
        _check();
    }

    /// @dev A fill of up to the bucket's whole pending, or nothing when it is unflushed or spent.
    function _fill(uint96 localId, bool isDeposit, uint256 seed, uint256 price) internal {
        Bucket memory b = h.bucket(localId);
        uint128 outstanding = h.outstanding(localId);
        if (!b.flushed || outstanding == 0) return;
        uint128 amount = uint128(bound(seed, 1, outstanding));
        uint128 other = uint128(bound(price, 1, 1e30));
        if (isDeposit) h.settle(localId, true, amount, other, 0, 0);
        else h.settle(localId, false, other, amount, 0, 0);
    }

    /// @dev A cancellation retaining a fee: gross retires pending, only net is credited.
    function _cancel(uint96 localId, uint256 grossSeed, uint256 netSeed) internal {
        Bucket memory b = h.bucket(localId);
        uint128 outstanding = h.outstanding(localId);
        if (!b.flushed || outstanding == 0) return;
        uint128 gross = uint128(bound(grossSeed, 1, outstanding));
        uint128 net = uint128(bound(netSeed, 0, gross));
        h.settle(localId, b.isDeposit, 0, 0, gross, net);
    }

    function _check() internal view {
        address[3] memory controllers = [alice, bob, carol];
        uint96[3] memory ids = [SHARED, REDEEM, IDLE];
        for (uint256 i; i < controllers.length; i++) {
            _assertEq(h.unfolded(controllers[i]), h.unfoldedReference(controllers[i], ids));
            for (uint256 j; j < ids.length; j++) {
                assertEq(h.pending(ids[j], controllers[i]), h.pendingReference(ids[j], controllers[i]), "pending");
            }
        }
    }

    function _assertEq(UnfoldedState memory u, UnfoldedState memory r) internal pure {
        assertEq(u.depositShares, r.depositShares, "depositShares");
        assertEq(u.depositAssets, r.depositAssets, "depositAssets");
        assertEq(u.redeemShares, r.redeemShares, "redeemShares");
        assertEq(u.redeemAssets, r.redeemAssets, "redeemAssets");
        assertEq(u.refundShares, r.refundShares, "refundShares");
        assertEq(u.refundAssets, r.refundAssets, "refundAssets");
        assertEq(u.depositPending, r.depositPending, "depositPending");
        assertEq(u.redeemPending, r.redeemPending, "redeemPending");
    }

    function _bit(uint16 flags, uint8 i) internal pure returns (bool) {
        return (flags >> i) & 1 == 1;
    }
}
