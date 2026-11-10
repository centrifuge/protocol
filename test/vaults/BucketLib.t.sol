// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {FoldResult, BucketReference} from "./BucketReference.sol";

import {BucketLib} from "../../src/vaults/libraries/BucketLib.sol";
import {HorizonLib} from "../../src/vaults/libraries/HorizonLib.sol";
import {VaultRequestIdLib} from "../../src/vaults/libraries/VaultRequestIdLib.sol";
import {IVaultErrors, IVaultEvents, InvestmentState, UnfoldedState} from "../../src/vaults/interfaces/IAsyncVault.sol";

import "forge-std/Test.sol";

/// @dev Thin harness exposing the internal library over a single `State`, so its invariants can be
///      exercised in isolation from the vault.
contract BucketHarness {
    using BucketLib for BucketLib.State;
    using HorizonLib for HorizonLib.State;
    using BucketReference for BucketLib.State;

    BucketLib.State internal s;
    HorizonLib.State internal h;
    InvestmentState internal _ledger;

    function contribute(uint96 localId, address controller, bool isDeposit, uint128 amount) external {
        s.contribute(localId, controller, isDeposit, amount, true, 0);
    }

    function contributeUnbatched(uint96 localId, address controller, bool isDeposit, uint128 amount) external {
        s.contribute(localId, controller, isDeposit, amount, false, 0);
    }

    function flush(uint96 localId) external returns (uint128, bool) {
        return s.flush(localId);
    }

    function settle(uint96 localId, uint128 assets, uint128 shares, uint128 cancelled) external {
        s.settle(localId, true, assets, shares, cancelled, cancelled);
    }

    /// @dev Cancellation with a retained fee: gross retires pending, effective is claimable.
    function settleCancelled(uint96 localId, uint128 cancelled, uint128 effective) external {
        s.settle(localId, true, 0, 0, cancelled, effective);
    }

    function fold(uint96 localId, address controller)
        external
        returns (uint128 assets, uint128 shares, uint128 cancelled, bool isDeposit, bool completed)
    {
        FoldResult memory r = s.fold(_ledger, localId, controller);
        return (r.assets, r.shares, r.cancelledGross, r.isDeposit, r.completed);
    }

    function foldEffective(uint96 localId, address controller) external returns (uint128) {
        return s.fold(_ledger, localId, controller).cancelledNet;
    }

    function unfoldedPendingOf(address controller) external view returns (uint128 deposit, uint128 redeem) {
        UnfoldedState memory u = h.unfolded(s, _ledger, controller);
        return (u.depositPending, u.redeemPending);
    }

    function remember(uint96 localId, address controller) external {
        h.add(s, _ledger, controller, localId, s.buckets[localId].isDeposit, true, 8);
    }

    function transfer(uint96 localId, address from, address to) external {
        bool isDeposit = s.buckets[localId].isDeposit;
        s.transfer(localId, from, to);
        h.remove(s, from, localId, isDeposit);
    }

    function track(uint96 localId, address controller, uint256 horizon) external {
        h.add(s, _ledger, controller, localId, s.buckets[localId].isDeposit, true, horizon);
    }

    function gift(uint96 localId, address controller, uint256 horizon) external {
        h.add(s, _ledger, controller, localId, s.buckets[localId].isDeposit, false, horizon);
    }

    function contains(uint96 localId, address controller) external view returns (bool) {
        return h.contains(s, controller, localId, s.buckets[localId].isDeposit);
    }

    function removeRecentFor(address controller, uint96 localId, bool isDeposit) external {
        h.remove(s, controller, localId, isDeposit);
    }

    function recentOf(address controller, bool isDeposit) external view returns (uint96[] memory) {
        return h.entries(s, controller, isDeposit);
    }

    /// @dev The overflow slots in use: an entry is never zero, so a slot with one in it is not either.
    function overflowSlotsOf(address controller, bool isDeposit) external view returns (uint256 slots) {
        while (h.more[controller][isDeposit][slots] != 0) {
            slots++;
        }
    }

    function foldRecent(address controller) external {
        h.fold(s, _ledger, controller);
    }

    function pendingTotal(address controller, bool isDeposit) external view returns (uint128) {
        return s.sides[controller][isDeposit].pending;
    }

    function settleRedeem(uint96 localId, uint128 assets, uint128 shares) external {
        s.settle(localId, false, assets, shares, 0, 0);
    }

    /// @dev A redeem bucket cancelled in part: the gross retires pending, the net is what refunds.
    function cancelRedeem(uint96 localId, uint128 gross, uint128 net) external {
        s.settle(localId, false, 0, 0, gross, net);
    }

    function ledger() external view returns (InvestmentState memory) {
        return _ledger;
    }

    /// @dev Sets one ledger counter, as claims and fills move it: 0 maxMint, 1 depositAssets, 2 maxWithdraw,
    ///      3 redeemShares, 4 refundShares, 5 refundAssets.
    function setLedger(uint256 field, uint128 value) external {
        if (field == 0) _ledger.depositShares = value;
        else if (field == 1) _ledger.depositAssets = value;
        else if (field == 2) _ledger.redeemAssets = value;
        else if (field == 3) _ledger.redeemShares = value;
        else if (field == 4) _ledger.refundShares = value;
        else _ledger.refundAssets = value;
    }

    function unfoldedOf(address controller) external view returns (UnfoldedState memory) {
        return h.unfolded(s, _ledger, controller);
    }

    function settleRedeemSide(uint96 localId, uint128 shares) external {
        s.settle(localId, false, 0, shares, 0, 0);
    }

    function settledOf(uint96 localId, address controller) external view returns (uint128 a, uint128 sh, uint128 c) {
        (a, sh, c,) = s.settled(localId, controller);
    }

    function pendingOf(uint96 localId, address controller) external view returns (uint128) {
        return s.pendingNow(localId, controller);
    }

    function contributionOf(uint96 localId, address controller) external view returns (uint128) {
        return s.contributions[localId][controller].amount;
    }

    function bucketTotal(uint96 localId) external view returns (uint128) {
        return s.buckets[localId].total;
    }
}

contract BucketLibTest is Test {
    BucketHarness h;

    uint96 constant LID = 3; // arbitrary deposit-side local id
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        h = new BucketHarness();
    }

    /// @dev A sole owner's fold leaves the bucket with no stakeholders, so it is retired and its local
    ///      id becomes reusable. This is what lets `PerInvestorPolicy` derive one permanent id per
    ///      (controller, side): without the retirement the settled `total` outlives the contribution and
    ///      the sealed check would reject every later request on that id, locking the controller out of
    ///      the vault after their first request completed.
    function testSoleOwnerBucketIsRetiredAndItsIdReusable() public {
        h.contribute(LID, alice, true, 1_000);
        h.flush(LID);
        h.settle(LID, 1_000, 500, 0);
        (,,,, bool completed) = h.fold(LID, alice);
        assertTrue(completed, "bucket fully settled and contribution cleaned up");
        assertEq(h.contributionOf(LID, alice), 0);
        assertEq(h.bucketTotal(LID), 0, "sole-owner fold retires the bucket");

        // The id is fresh again: a new cycle contributes, flushes and settles like the first.
        h.contribute(LID, alice, true, 2_000);
        assertEq(h.bucketTotal(LID), 2_000, "new cycle starts from zero, not from the old total");
        (uint128 queued,) = h.flush(LID);
        assertEq(queued, 2_000);
        h.settle(LID, 2_000, 1_000, 0);
        (uint128 assets, uint128 shares,,,) = h.fold(LID, alice);
        assertEq(assets, 2_000, "second cycle settles on its own total, not blended with the first");
        assertEq(shares, 1_000);
    }

    /// @dev The other half: a shared bucket is never retired, because no contributor's fold proves the
    ///      bucket is empty — each holds only part of the total. Its totals therefore outlive every
    ///      fold, which is harmless: only `PerInvestorPolicy` reuses a local id, and its buckets always
    ///      have exactly one contributor. A batching policy mints a fresh id per window.
    function testSharedBucketIsNeverRetired() public {
        h.contribute(LID, alice, true, 600);
        h.contribute(LID, bob, true, 400);
        h.flush(LID);
        h.settle(LID, 1_000, 500, 0);

        h.fold(LID, alice);
        assertEq(h.bucketTotal(LID), 1_000, "denominator intact for the contributor who has not folded");

        (uint128 assets, uint128 shares,,,) = h.fold(LID, bob);
        assertEq(assets, 400, "bob still gets his pro-rata slice");
        assertEq(shares, 200);
        assertEq(h.bucketTotal(LID), 1_000, "kept: no single fold can prove the bucket is empty");
    }

    function _rid(uint96 localId) internal view returns (uint256) {
        return VaultRequestIdLib.from(address(h), localId).raw();
    }

    /// @dev A fold that completes a contribution says so, and says whether it retired the bucket, because an
    ///      indexer cannot see either from the claimable events.
    function testACompletingFoldEmitsRequestFolded() public {
        h.contribute(LID, alice, true, 1_000);
        h.flush(LID);
        h.settle(LID, 1_000, 500, 0);
        vm.expectEmit(true, true, false, true, address(h));
        emit IVaultEvents.RequestFolded(_rid(LID), alice, true, 1_000, 500, 0, 0, 0, true, true);
        h.fold(LID, alice);
    }

    function testASharedBucketCompletesWithoutRetiring() public {
        h.contribute(LID, alice, true, 600);
        h.contribute(LID, bob, true, 400);
        h.flush(LID);
        h.settle(LID, 1_000, 500, 0);
        vm.expectEmit(true, true, false, true, address(h));
        emit IVaultEvents.RequestFolded(_rid(LID), alice, true, 600, 300, 0, 0, 0, true, false);
        h.fold(LID, alice);
    }

    /// @dev A cancellation whose net is zero credits nothing but still retires pending, so the fold reports it.
    function testAFoldThatCreditsNothingReportsThePendingItReduced() public {
        h.contribute(1, alice, true, 1_000);
        h.flush(1);
        h.settleCancelled(1, 400, 0);
        vm.expectEmit(true, true, false, true, address(h));
        emit IVaultEvents.RequestFolded(_rid(1), alice, true, 0, 0, 400, 0, 600, false, false);
        h.fold(1, alice);
    }

    /// @dev A crediting fold is logged too, with the retained fee as the difference of the gross and the net.
    function testACreditingFoldEmitsRequestFoldedWithTheGrossAndNetCancelled() public {
        h.contribute(1, alice, true, 1_000);
        h.flush(1);
        h.settleCancelled(1, 400, 380);
        vm.expectEmit(true, true, false, true, address(h));
        emit IVaultEvents.CancelDepositClaimable(_rid(1), alice, 380);
        vm.expectEmit(true, true, false, true, address(h));
        emit IVaultEvents.RequestFolded(_rid(1), alice, true, 0, 0, 400, 380, 600, false, false);
        h.fold(1, alice);
    }

    function testAFillAndACancellationFoldInOneRequestFolded() public {
        h.contribute(1, alice, true, 1_000);
        h.flush(1);
        h.settle(1, 500, 250, 0);
        h.settleCancelled(1, 200, 190);
        vm.expectEmit(true, true, false, true, address(h));
        emit IVaultEvents.RequestFolded(_rid(1), alice, true, 500, 250, 200, 190, 300, false, false);
        h.fold(1, alice);
    }

    function testASecondFoldReportsOnlyWhatIsNewSinceTheFirst() public {
        h.contribute(1, alice, true, 1_000);
        h.flush(1);
        h.settle(1, 300, 150, 0);
        h.fold(1, alice);
        h.settleCancelled(1, 200, 190);
        vm.expectEmit(true, true, false, true, address(h));
        emit IVaultEvents.RequestFolded(_rid(1), alice, true, 0, 0, 200, 190, 500, false, false);
        h.fold(1, alice);
    }

    function testTheFirstContributionOpensTheBucket() public {
        vm.expectEmit(true, false, false, true, address(h));
        emit IVaultEvents.BucketOpened(_rid(1), true, 0);
        h.contribute(1, alice, true, 100);

        vm.recordLogs();
        h.contribute(1, bob, true, 50);
        assertEq(vm.getRecordedLogs().length, 0, "a second contribution opens nothing");
    }

    function testARetiredBucketIsOpenedAgainByTheNextContribution() public {
        h.contribute(LID, alice, true, 1_000);
        h.flush(LID);
        h.settle(LID, 1_000, 500, 0);
        h.fold(LID, alice);

        vm.expectEmit(true, false, false, true, address(h));
        emit IVaultEvents.BucketOpened(_rid(LID), false, 0);
        h.contribute(LID, alice, false, 10);
    }

    function testSoleOwnerMayExtendAfterFlush() public {
        h.contribute(LID, alice, true, 100);
        h.flush(LID);
        // Alice owns the whole (flushed) bucket, so she may keep adding.
        h.contribute(LID, alice, true, 50);
        assertEq(h.contributionOf(LID, alice), 150);
        assertEq(h.bucketTotal(LID), 150);
    }

    function testNonOwnerRejectedAfterFlush() public {
        h.contribute(LID, alice, true, 100);
        h.flush(LID);
        vm.expectRevert(IVaultErrors.BucketSealed.selector);
        h.contribute(LID, bob, true, 50);
    }

    function testMultipleContributorsBeforeFlush() public {
        h.contribute(LID, alice, true, 100);
        h.contribute(LID, bob, true, 300);
        h.flush(LID);
        assertEq(h.bucketTotal(LID), 400);
    }

    /// @dev Fix for the stranded-reservation bug: gross retires pending, effective is claimable, and the
    ///      difference is the retained cancellation fee.
    function testCancellationSplitsGrossAndEffective() public {
        h.contribute(1, alice, true, 1000);
        h.flush(1);
        h.settleCancelled(1, 400, 380); // 20 retained as a cancellation fee

        (uint128 a, uint128 sh, uint128 c) = h.settledOf(1, alice);
        assertEq(a, 0);
        assertEq(sh, 0);
        assertEq(c, 400, "gross retires pending");
        assertEq(h.pendingOf(1, alice), 600, "only the gross amount leaves pending");
        assertEq(h.foldEffective(1, alice), 380, "the investor claims the effective amount");
    }

    /// @dev A rebate (effective > gross) must not be clamped: the pool pre-funds the difference.
    function testCancellationAllowsARebate() public {
        h.contribute(1, alice, true, 1000);
        h.flush(1);
        h.settleCancelled(1, 400, 420);
        assertEq(h.pendingOf(1, alice), 600);
        assertEq(h.foldEffective(1, alice), 420);
    }

    /// @dev Cancellation is order-level: on a multi-contributor bucket a partial cancellation is a
    ///      proportional scale-down, with gross retiring pending and effective credited pro-rata, so a
    ///      cancellation fee is borne proportionally too.
    function testMultiContributorCancellationIsProportional() public {
        h.contribute(1, alice, true, 600);
        h.contribute(1, bob, true, 400);
        h.flush(1);
        h.settleCancelled(1, 400, 380); // scale the window down 40%, 5% cancellation fee

        (,, uint128 aliceGross) = h.settledOf(1, alice);
        (,, uint128 bobGross) = h.settledOf(1, bob);
        assertEq(aliceGross, 240, "alice: 60% of the gross cancellation");
        assertEq(bobGross, 160, "bob: 40% of the gross cancellation");
        assertEq(h.pendingOf(1, alice), 360, "pending retires by the gross slice");
        assertEq(h.pendingOf(1, bob), 240);
        assertEq(h.foldEffective(1, alice), 228, "claimable is the effective slice");
        assertEq(h.foldEffective(1, bob), 152);
    }

    /// @dev A full-remainder cancellation rejects the window: every contributor is made whole and the
    ///      bucket fully settles, combining with any fills that landed first.
    function testMultiContributorFullCancellationRejectsWindow() public {
        h.contribute(1, alice, true, 600);
        h.contribute(1, bob, true, 400);
        h.flush(1);
        h.settle(1, 500, 250, 0); // half fills first
        h.settleCancelled(1, 500, 500); // the remainder is rejected, fee-free

        (uint128 aliceAssets,, uint128 aliceGross) = h.settledOf(1, alice);
        assertEq(aliceAssets + aliceGross, 600, "filled slice plus refund covers the contribution");
        assertEq(h.pendingOf(1, alice), 0);
        assertEq(h.pendingOf(1, bob), 0);
    }

    function testSideMismatchReverts() public {
        h.contribute(LID, alice, true, 100);
        vm.expectRevert(IVaultErrors.RequestIdInUse.selector);
        h.contribute(LID, bob, false, 100);
    }

    function testUnbatchedJoinOfAnotherBucketReverts() public {
        h.contribute(LID, alice, true, 100);
        vm.expectRevert(IVaultErrors.RequestIdInUse.selector);
        h.contributeUnbatched(LID, bob, true, 100);

        h.contributeUnbatched(LID + 1, alice, true, 100);
        vm.expectRevert(IVaultErrors.RequestIdInUse.selector);
        h.contributeUnbatched(LID + 1, bob, true, 100);

        h.contributeUnbatched(LID + 1, alice, true, 40);
    }

    function testFlushRepeatableForSoleOwner() public {
        h.contribute(LID, alice, true, 100);
        (uint128 first,) = h.flush(LID);
        assertEq(first, 100);
        h.contribute(LID, alice, true, 40);
        (uint128 second,) = h.flush(LID);
        assertEq(second, 40, "second flush sends only the new queued delta");
    }

    function testFoldIsMonotoneAndNoDoubleCount() public {
        h.contribute(LID, alice, true, 100);
        h.contribute(LID, bob, true, 100);
        h.flush(LID);

        // Partial fulfillment: 100 of 200 assets, 50 shares.
        h.settle(LID, 100, 50, 0);
        (uint128 a1,,,,) = h.fold(LID, alice);
        assertEq(a1, 50, "alice half of the partial");
        // Folding again with no new settlement yields zero (no double count).
        (uint128 a2,,,,) = h.fold(LID, alice);
        assertEq(a2, 0);

        // Remaining fulfillment.
        h.settle(LID, 100, 50, 0);
        (uint128 a3,,,, bool done) = h.fold(LID, alice);
        assertEq(a3, 50, "alice second half");
        assertTrue(done, "fully settled -> contribution cleaned up");
    }

    /// @dev A settlement may only land on a bucket that is closed to new contributors. Without the
    ///      guard, a contributor joining after a settlement grows the denominator under an earlier
    ///      contributor whose folded snapshot was taken against the smaller one: their slice shrinks
    ///      below what they already folded, every later fold underflows, and — since the vault folds
    ///      on every claim — their position can no longer be claimed at all. The shipped policies
    ///      always flush before the hub can answer; this binds a locally-registered request manager,
    ///      which settles the vault with plain typed calls.
    function testSettlingAnUnflushedBucketReverts() public {
        h.contribute(LID, alice, true, 100);

        vm.expectRevert(IVaultErrors.BucketNotFlushed.selector);
        h.settle(LID, 50, 50, 0);

        h.flush(LID);
        h.settle(LID, 50, 50, 0);

        // Flushed, so the late contributor is refused rather than diluting alice's folded slice.
        h.fold(LID, alice);
        vm.expectRevert(IVaultErrors.BucketSealed.selector);
        h.contribute(LID, bob, true, 900);

        (uint128 settled,,) = h.settledOf(LID, alice);
        assertEq(settled, 50, "alice's slice is measured against the denominator she folded against");
    }

    //----------------------------------------------------------------------------------------------
    // Settlement obligations
    //----------------------------------------------------------------------------------------------

    /// @dev A fulfillment prices one unit against the other. A non-zero leg against a zero one is not
    ///      a cheap fill: it retires the request and consumes the escrowed side while crediting
    ///      nothing back, which is unrecoverable for the investor.
    function testFulfillmentWithAZeroLegReverts() public {
        h.contribute(LID, alice, true, 1_000);
        h.flush(LID);

        vm.expectRevert(IVaultErrors.OneSidedFill.selector);
        h.settle(LID, 500, 0, 0);

        vm.expectRevert(IVaultErrors.OneSidedFill.selector);
        h.settle(LID, 0, 500, 0);

        h.settle(LID, 500, 250, 0);
    }

    /// @dev A cancellation carries neither leg, so it is not caught by the rule above.
    function testCancellationNeedsNoConsideration() public {
        h.contribute(LID, alice, true, 1_000);
        h.flush(LID);

        h.settleCancelled(LID, 1_000, 1_000);
        assertEq(h.pendingOf(LID, alice), 0);
    }

    /// @dev `pending` saturates, so without an explicit bound one over-sized callback would inflate
    ///      the bucket's fulfilled totals and with them every contributor's pro-rata slice — letting
    ///      this bucket's claims draw on backing that belongs to another.
    function testSettlingMoreThanTheBucketRequestedReverts() public {
        h.contribute(LID, alice, true, 1_000);
        h.flush(LID);

        vm.expectRevert(IVaultErrors.OverSettled.selector);
        h.settle(LID, 1_001, 1_001, 0);

        h.settle(LID, 600, 600, 0);

        vm.expectRevert(IVaultErrors.OverSettled.selector);
        h.settle(LID, 401, 401, 0);

        h.settle(LID, 400, 400, 0);
    }

    /// @dev The over-settlement bound is the cumulative flushed amount, not `total`. A sole owner may
    ///      keep extending a flushed bucket, and that top-up sits in `queued` until it is flushed in
    ///      turn — bounded by `total`, a settlement would land on value the hub was never told about.
    ///      The `flushed` check is per-bucket, so on its own it stops only the first such settlement.
    function testASettlementCannotLandOnAnUnflushedTopUp() public {
        h.contribute(LID, alice, true, 1_000);
        h.flush(LID);
        h.settle(LID, 1_000, 1_000, 0);

        // The sole owner extends. The hub has not been told about this 500.
        h.contribute(LID, alice, true, 500);

        vm.expectRevert(IVaultErrors.OverSettled.selector);
        h.settle(LID, 500, 500, 0);

        // It becomes settleable exactly when it is sent.
        h.flush(LID);
        h.settle(LID, 500, 500, 0);
    }

    /// @dev The bound tracks what was sent, so a top-up queued while an earlier flush is still
    ///      outstanding does not block that earlier settlement.
    function testATopUpDoesNotBlockAnOutstandingSettlement() public {
        h.contribute(LID, alice, true, 1_000);
        h.flush(LID);

        // Extends before the hub answers the first request.
        h.contribute(LID, alice, true, 500);

        // The flushed 1000 still settles in full.
        h.settle(LID, 1_000, 1_000, 0);

        // And the top-up follows once it is sent in its turn.
        h.flush(LID);
        h.settle(LID, 500, 500, 0);
    }

    function testCancellationCannotExceedTheBucketEither() public {
        h.contribute(LID, alice, true, 1_000);
        h.flush(LID);
        h.settle(LID, 600, 600, 0);

        vm.expectRevert(IVaultErrors.OverSettled.selector);
        h.settleCancelled(LID, 401, 401);

        h.settleCancelled(LID, 400, 400);
    }

    //----------------------------------------------------------------------------------------------
    // Floor-rounding residue
    //----------------------------------------------------------------------------------------------

    /// @dev Slices floor, so a shared bucket cannot credit every contributor the exact amount they
    ///      put in. A spent bucket has nothing left to settle for anyone, so that remainder is not
    ///      pending; if it read as pending it would sit there forever, and the vault reads any
    ///      non-zero pending as "still async" — closing the instant lane permanently.
    function testASpentBucketHasNothingPending() public {
        // Three contributors of 1. The window fills 2 and the manager cancels the remaining 1, so the
        // bucket settles fully while every contributor's slice of both amounts floors to zero.
        h.contribute(LID, alice, true, 1);
        h.contribute(LID, bob, true, 1);
        h.contribute(LID, carol, true, 1);
        h.flush(LID);
        h.settle(LID, 2, 2, 0);
        h.settleCancelled(LID, 1, 1);

        (uint128 assets,,) = h.settledOf(LID, alice);
        assertEq(assets, 0, "alice's slice floors away");
        assertEq(h.pendingOf(LID, alice), 0, "yet nothing of hers is still pending");
    }

    function testAContributionIsPendingWhileTheBucketIsStillSettling() public {
        h.contribute(LID, alice, true, 1_000);
        h.flush(LID);
        h.settle(LID, 400, 400, 0);

        assertEq(h.pendingOf(LID, alice), 600, "what the hub has not answered yet");
    }

    /// @dev The aggregate view has to agree with the per-bucket one, or folding would be observable
    ///      as a jump in the reported pending amount.
    function testTheAggregateViewDropsTheRemainderToo() public {
        h.contribute(LID, alice, true, 3);
        h.contribute(LID, bob, true, 4);
        h.remember(LID, alice);
        h.flush(LID);
        h.settle(LID, 5, 5, 0);
        h.settleCancelled(LID, 2, 2);

        // Alice is credited floor(5*3/7) = 2 assets and floor(2*3/7) = 0 cancelled, so one unit of her
        // contribution is remainder. The bucket is spent, so none of the three is still pending.
        (uint128 depositPending,) = h.unfoldedPendingOf(alice);
        assertEq(depositPending, 0, "a spent bucket leaves alice nothing pending");

        h.fold(LID, alice);
        assertEq(h.contributionOf(LID, alice), 0, "and the fold agrees");
        assertEq(h.pendingTotal(alice, true), 0, "the dust leaves the pending total with the fold");
    }

    //----------------------------------------------------------------------------------------------
    // Guards
    //----------------------------------------------------------------------------------------------

    /// @dev Flushing sends the queued amount, so an empty queue has nothing to send: the vault would
    ///      otherwise pay for a hub message carrying a zero request.
    function testFlushWithNothingQueuedReverts() public {
        vm.expectRevert(IVaultErrors.NoQueuedRequest.selector);
        h.flush(LID);

        h.contribute(LID, alice, true, 100);
        h.flush(LID);

        // The queue is drained by the flush, so an immediate second one has nothing left either.
        vm.expectRevert(IVaultErrors.NoQueuedRequest.selector);
        h.flush(LID);
    }

    function testSettleOnABucketWithNoPendingReverts() public {
        vm.expectRevert(IVaultErrors.NoPendingRequest.selector);
        h.settle(LID, 100, 100, 0);

        h.contribute(LID, alice, true, 100);
        h.flush(LID);
        h.settle(LID, 100, 100, 0);

        // Fully settled: a second settlement has nothing left to apply and must not silently inflate
        // the bucket's fulfilled totals, which every contributor's slice is measured against.
        vm.expectRevert(IVaultErrors.NoPendingRequest.selector);
        h.settle(LID, 1, 1, 0);
    }

    /// @dev A settlement carries its side, and applying a redeem fulfillment to a deposit bucket would
    ///      credit shares where assets were contributed.
    function testSettleFromTheWrongSideReverts() public {
        h.contribute(LID, alice, true, 100);
        h.flush(LID);

        vm.expectRevert(IVaultErrors.NoPendingRequest.selector);
        h.settleRedeemSide(LID, 100);
    }

    function testTransferToSelfReverts() public {
        h.contribute(LID, alice, true, 100);

        vm.expectRevert(IVaultErrors.InvalidController.selector);
        h.transfer(LID, alice, alice);
    }

    /// @dev A zero-amount source has nothing to move, so a transfer from it is an error, not a no-op.
    function testTransferFromANonContributorReverts() public {
        h.contribute(LID, alice, true, 100);

        vm.expectRevert(IVaultErrors.NoContribution.selector);
        h.transfer(LID, bob, carol);
    }

    function testTransferMovesTheWholeContribution() public {
        h.contribute(LID, alice, true, 100);

        h.transfer(LID, alice, bob);
        assertEq(h.contributionOf(LID, alice), 0, "the sender keeps nothing");
        assertEq(h.contributionOf(LID, bob), 100, "and the recipient holds it all");
        assertEq(h.bucketTotal(LID), 100, "the denominator is untouched, so no other slice moves");
        assertEq(h.pendingTotal(alice, true), 0, "the pending total moves with it");
        assertEq(h.pendingTotal(bob, true), 100);

        h.contribute(LID, carol, true, 100);
        h.transfer(LID, carol, bob);
        assertEq(h.contributionOf(LID, bob), 200, "an existing stake is topped up");
        assertEq(h.pendingTotal(bob, true), 200);
    }

    /// @dev The sum of contributors' settled slices never exceeds the bucket's fulfilled total
    ///      (floor rounding leaves dust in escrow), and each slice is proportional.
    function testBucketConservation(uint128 aliceAmt, uint128 bobAmt, uint128 fulfilled) public {
        aliceAmt = uint128(bound(aliceAmt, 1, 1e30));
        bobAmt = uint128(bound(bobAmt, 1, 1e30));
        uint256 total = uint256(aliceAmt) + bobAmt;
        fulfilled = uint128(bound(fulfilled, 0, total));

        h.contribute(LID, alice, true, aliceAmt);
        h.contribute(LID, bob, true, bobAmt);
        h.flush(LID);
        h.settle(LID, fulfilled, fulfilled, 0);

        (uint128 sa,,) = h.settledOf(LID, alice);
        (uint128 sb,,) = h.settledOf(LID, bob);
        assertLe(uint256(sa) + sb, fulfilled, "settled never exceeds fulfilled");
        // Dust is at most one unit per contributor (floor rounding).
        assertGe(uint256(sa) + sb + 2, fulfilled, "dust bounded by contributor count");
        assertEq(sa, uint128(uint256(fulfilled) * aliceAmt / total), "alice exact pro-rata");
    }

    //----------------------------------------------------------------------------------------------
    // Documented non-guarantees
    //----------------------------------------------------------------------------------------------

    /// @dev `n`: "Settlement is idempotent". `settle` accumulates, so the same callback applied twice
    ///      is counted twice — the contributor's slice doubles and the bucket retires early. Non-replay
    ///      is the messaging layer's guarantee, not this library's, and pinning it here is what keeps
    ///      that division of labour visible: if this ever starts deduplicating, the assumption the
    ///      gateway is carrying has changed.
    function testSettlementIsNotIdempotent() public {
        h.contribute(LID, alice, true, 1_000);
        h.flush(LID);

        h.settle(LID, 400, 400, 0);
        (uint128 once,,) = h.settledOf(LID, alice);
        assertEq(once, 400);

        h.settle(LID, 400, 400, 0);
        (uint128 twice,,) = h.settledOf(LID, alice);
        assertEq(twice, 800, "the same fulfillment counted twice");
        assertEq(h.pendingOf(LID, alice), 200, "and retired twice the pending");
    }

    /// @dev The 2-argument routing reads the per-controller pending total, which a horizon fold brings current.
    function testFoldRecentLeavesThePendingTotalTheRoutingReads() public {
        h.contribute(LID, alice, true, 600);
        h.contribute(LID, bob, true, 400);
        h.flush(LID);
        h.track(LID, alice, 4);

        h.settle(LID, 500, 500, 0);
        h.foldRecent(alice);
        assertEq(h.pendingTotal(alice, true), 300, "alice still has 300 of her 600 pending");

        h.settle(LID, 500, 500, 0);
        h.foldRecent(alice);
        assertEq(h.pendingTotal(alice, true), 0, "settled in full");
    }

    /// @dev A full horizon makes way by its oldest entry, and tracking a position it holds changes nothing.
    function testAFullHorizonMakesWayByItsOldest() public {
        h.contribute(1, alice, true, 100);
        h.contribute(2, alice, true, 100);
        h.contribute(3, alice, true, 100);

        h.track(1, alice, 2);
        h.track(2, alice, 2);
        h.track(1, alice, 2);
        h.track(3, alice, 2);

        assertFalse(h.contains(1, alice), "the oldest went");
        assertTrue(h.contains(2, alice));
        assertTrue(h.contains(3, alice));
    }

    /// @dev A position the controller did not submit takes a free slot and never evicts one of theirs: with the
    ///      horizon full it is not tracked, and waits for `foldRequest`.
    function testAGiftTakesAFreeSlotAndNeverEvicts() public {
        h.contribute(1, alice, true, 100);
        h.contribute(2, alice, true, 100);
        h.contribute(3, alice, true, 100);

        h.track(1, alice, 2);
        h.gift(2, alice, 2);
        assertTrue(h.contains(2, alice), "a free slot takes the gift");

        h.gift(3, alice, 2);
        assertFalse(h.contains(3, alice), "a full horizon does not make way for a gift");
        assertTrue(h.contains(1, alice), "the controller's own position stayed");
        assertTrue(h.contains(2, alice));
    }

    /// @dev A keeper learns of every position only `foldRequest` can credit: a gift the full horizon has no room for,
    ///      and an own position's eviction of an unsettled one.
    function testAPositionLeftOutsideTheHorizonIsReported() public {
        h.contribute(1, alice, true, 100);
        h.contribute(2, alice, true, 100);
        h.contribute(3, alice, true, 100);
        h.track(1, alice, 1);

        vm.expectEmit(true, true, false, true, address(h));
        emit IVaultEvents.OutsideHorizon(_rid(2), alice, true);
        h.gift(2, alice, 1);

        vm.expectEmit(true, true, false, true, address(h));
        emit IVaultEvents.OutsideHorizon(_rid(1), alice, true);
        h.track(3, alice, 1);
    }

    /// @dev An eviction whose fold completes the position leaves nothing for a keeper, so it reports nothing.
    function testAnEvictionThatCompletesThePositionReportsNothing() public {
        h.contribute(1, alice, true, 100);
        h.contribute(2, alice, true, 100);
        h.flush(1);
        h.track(1, alice, 1);
        h.settle(1, 100, 100e12, 0);

        vm.recordLogs();
        h.track(2, alice, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != IVaultEvents.OutsideHorizon.selector, "nothing is left outside");
        }
        assertFalse(h.contains(1, alice), "evicted");
    }

    /// @dev An unsettled position the horizon evicts leaves the claim's fold, not the pending total: the routing still
    ///      sees it, so the instant lane stays closed while it is pending.
    function testAnEvictedPendingPositionStillCountsAsPending() public {
        h.contribute(1, alice, true, 100);
        h.contribute(2, alice, true, 200);
        h.flush(1);
        h.flush(2);

        h.track(1, alice, 1);
        h.track(2, alice, 1);
        assertFalse(h.contains(1, alice), "evicted");

        h.foldRecent(alice);
        assertEq(h.pendingTotal(alice, true), 300, "both still pending");
    }

    //----------------------------------------------------------------------------------------------
    // The horizon's storage: its first entry and count share the controller's slot, the rest overflow
    //----------------------------------------------------------------------------------------------

    function _track(uint96 first, uint96 last, uint256 horizon) internal {
        for (uint96 id = first; id <= last; id++) {
            h.contribute(id, alice, true, 100);
            h.track(id, alice, horizon);
        }
    }

    /// @dev Entries come back oldest first however many fit in the controller's slot, and the overflow array holds
    ///      exactly the ones after the first.
    function testTheHorizonKeepsItsOrderAcrossTheSlotAndTheOverflow() public {
        assertEq(h.recentOf(alice, true).length, 0, "empty to start");
        assertEq(h.overflowSlotsOf(alice, true), 0);

        _track(1, 1, 4);
        assertEq(h.recentOf(alice, true).length, 1);
        assertEq(h.overflowSlotsOf(alice, true), 0, "one entry never touches the overflow");

        _track(2, 4, 4);
        uint96[] memory ids = h.recentOf(alice, true);
        assertEq(ids.length, 4);
        for (uint96 i; i < 4; i++) {
            assertEq(ids[i], i + 1, "oldest first");
        }
        assertEq(h.overflowSlotsOf(alice, true), 1, "the first two are in the controller's slot, the rest share one");
        assertEq(h.recentOf(alice, false).length, 0, "the other side is its own horizon");
    }

    /// @dev A full horizon makes room for a new entry by folding and dropping the oldest, and the overflow array
    ///      keeps its length.
    function testAFullHorizonEvictsTheOldestEntry() public {
        _track(1, 3, 3);
        _track(4, 4, 3);

        uint96[] memory ids = h.recentOf(alice, true);
        assertEq(ids.length, 3);
        assertEq(ids[0], 2);
        assertEq(ids[1], 3);
        assertEq(ids[2], 4);
        assertEq(h.overflowSlotsOf(alice, true), 1, "the third entry is the first in the overflow");
    }

    /// @dev Dropping the first entry promotes the second into the controller's slot, and dropping them all empties
    ///      both places.
    function testDroppingEntriesFromTheFrontMiddleAndBack() public {
        _track(1, 4, 4);

        h.removeRecentFor(alice, 2, true);
        uint96[] memory ids = h.recentOf(alice, true);
        assertEq(ids.length, 3, "a middle entry went");
        assertEq(ids[0], 1);
        assertEq(ids[1], 3);
        assertEq(ids[2], 4);
        assertEq(h.overflowSlotsOf(alice, true), 1);

        h.removeRecentFor(alice, 1, true);
        ids = h.recentOf(alice, true);
        assertEq(ids.length, 2, "the first went, so the second took its place");
        assertEq(ids[0], 3);
        assertEq(ids[1], 4);
        assertEq(h.overflowSlotsOf(alice, true), 0, "two entries fit the controller's slot");

        h.removeRecentFor(alice, 4, true);
        h.removeRecentFor(alice, 3, true);
        assertEq(h.recentOf(alice, true).length, 0);
        assertEq(h.overflowSlotsOf(alice, true), 0);

        // Empty again, a new entry starts over in the controller's slot
        _track(5, 5, 4);
        assertEq(h.recentOf(alice, true)[0], 5);
        assertEq(h.overflowSlotsOf(alice, true), 0);
    }

    /// @dev Past six entries the overflow takes a second slot, and dropping from the front shifts across both.
    function testTheOverflowSpansSlotsAndShiftsAcrossThem() public {
        _track(1, 7, 8);
        uint96[] memory ids = h.recentOf(alice, true);
        assertEq(ids.length, 7);
        for (uint96 i; i < 7; i++) {
            assertEq(ids[i], i + 1, "oldest first across the slot boundary");
        }
        assertEq(h.overflowSlotsOf(alice, true), 2);

        h.removeRecentFor(alice, 1, true);
        ids = h.recentOf(alice, true);
        assertEq(ids.length, 6);
        assertEq(ids[0], 2);
        assertEq(ids[5], 7);
        assertEq(h.overflowSlotsOf(alice, true), 1, "six entries need one overflow slot");

        h.removeRecentFor(alice, 5, true);
        ids = h.recentOf(alice, true);
        assertEq(ids.length, 5);
        assertEq(ids[3], 6, "the middle drop closed the gap");
        assertEq(h.overflowSlotsOf(alice, true), 1);
    }

    /// @dev A fold that settles the horizon's entries drops them from storage in order, whichever of them are done.
    function testFoldingDropsSettledEntriesAndKeepsThePendingOnes() public {
        for (uint96 id = 1; id <= 3; id++) {
            h.contribute(id, alice, true, 100);
            h.track(id, alice, 4);
            h.flush(id);
        }
        h.settle(1, 100, 100, 0);
        h.settle(3, 100, 100, 0);

        h.foldRecent(alice);
        uint96[] memory ids = h.recentOf(alice, true);
        assertEq(ids.length, 1);
        assertEq(ids[0], 2);
        assertEq(h.overflowSlotsOf(alice, true), 0);
        assertEq(h.pendingTotal(alice, true), 100, "only the second is left in the pending total");
    }

    /// @dev The fold that completes a contribution credits what it had not yet taken and leaves nothing behind,
    ///      without ever writing the snapshots it would delete.
    function testTheClosingFoldCreditsOnlyWhatWasNotFoldedBefore() public {
        h.contribute(LID, alice, true, 600);
        h.contribute(LID, bob, true, 400);
        h.flush(LID);

        h.settle(LID, 500, 500, 0);
        (uint128 firstAssets,,,, bool done) = h.fold(LID, alice);
        assertEq(firstAssets, 300, "her share of the first part");
        assertFalse(done, "not complete yet");

        h.settle(LID, 500, 500, 0);
        (uint128 secondAssets,,,, bool completed) = h.fold(LID, alice);
        assertEq(secondAssets, 300, "only the rest");
        assertTrue(completed);
        assertEq(h.contributionOf(LID, alice), 0, "her contribution is gone");
        assertEq(h.pendingTotal(alice, true), 0, "and so is her pending");
        assertEq(h.pendingOf(LID, bob), 0);
    }

    /// @dev A contribution folded for the first time in the settling fold credits its whole slice, with a
    ///      cancellation carrying a retained fee.
    function testAClosingFoldWithACancellationCreditsTheNetAndRetiresTheGross() public {
        h.contribute(LID, alice, true, 1_000);
        h.flush(LID);
        h.settleCancelled(LID, 1_000, 900);

        uint128 effective = h.foldEffective(LID, alice);
        assertEq(effective, 900, "the net is claimable");
        assertEq(h.contributionOf(LID, alice), 0);
        assertEq(h.pendingTotal(alice, true), 0, "the gross retired the pending");
    }

    /// @dev A horizon with no bound holds whatever is added to it.
    function testAnUnboundedHorizonIsClamped() public {
        _track(1, 3, type(uint256).max);
        assertEq(h.recentOf(alice, true).length, 3);
        assertEq(h.overflowSlotsOf(alice, true), 1);
    }

    //----------------------------------------------------------------------------------------------
    // A ledger counter at the top of its range: the fold defers instead of overflowing
    //----------------------------------------------------------------------------------------------

    uint128 constant MAX = type(uint128).max;

    function _redeemFill() internal {
        h.contribute(LID, alice, false, 1_000);
        h.flush(LID);
        h.settleRedeem(LID, 500, 1_000);
    }

    /// @dev A credit that would carry a ledger counter past `uint128` changes nothing and reverts nothing: the
    ///      position stays unfolded and pending as it was, and once a claim makes room the next fold credits all of
    ///      it. A checked add reverted every fold, and a claim folds first, so there was no way to make room.
    function testAFoldThatWouldOverflowTheRedeemLedgerIsDeferredNotReverted() public {
        _redeemFill();
        h.remember(LID, alice);
        h.setLedger(3, MAX - 100); // redeemShares: the fill's 1,000 shares do not fit
        h.setLedger(2, 7);

        (,,,, bool completed) = h.fold(LID, alice);
        assertFalse(completed, "a deferred fold completes nothing");
        InvestmentState memory l = h.ledger();
        assertEq(l.redeemShares, MAX - 100, "the counter is untouched");
        assertEq(l.redeemAssets, 7, "and so is the other");
        assertEq(h.contributionOf(LID, alice), 1_000, "the position is still there");
        assertEq(h.pendingTotal(alice, false), 1_000, "and still wholly pending");

        // A claim takes most of the ledger out; the next fold finds room
        h.setLedger(3, 0);
        (uint128 assets,,,, bool done) = h.fold(LID, alice);
        assertEq(assets, 500, "the whole fill is credited");
        assertTrue(done);
        l = h.ledger();
        assertEq(l.redeemShares, 1_000);
        assertEq(l.redeemAssets, 507);
        assertEq(h.contributionOf(LID, alice), 0);
    }

    /// @dev A cancellation whose gross slice floors to zero can still carry a net slice of one, when the net exceeds the
    ///      gross. The vault never sends that (`NetExceedsGross`), but the library takes it from a direct caller, and
    ///      credits the slice once: a later settlement's fold does not credit it again.
    function testANetOnlyCancellationSliceIsCreditedOnce() public {
        h.contribute(1, alice, true, 1);
        h.contribute(1, bob, true, 19);
        h.flush(1);
        h.settleCancelled(1, 10, 20);
        h.fold(1, alice);
        uint128 refunded = h.ledger().refundAssets;
        assertEq(refunded, 1, "a gross slice of zero, a net slice of one");

        h.settle(1, 5, 50, 0);
        h.fold(1, alice);
        assertEq(h.ledger().refundAssets, refunded, "credited once, not again on the next settlement");
    }

    /// @dev A horizon entry whose id was reused on the other side is stale: the claim fold drops it without folding the
    ///      other side's position into this side's ledger.
    function testAnEntryReusedOnTheOtherSideIsDroppedByTheFold() public {
        _reuseOnTheRedeemSide();
        h.foldRecent(alice);
        assertEq(h.ledger().redeemAssets, 0, "the redemption was not folded through the deposit side's entry");
        assertEq(h.contributionOf(1, alice), 50, "and is still there to fold");
        assertEq(h.recentOf(alice, true).length, 0, "the stale entry is gone");
    }

    /// @dev The same on eviction: a stale entry at the front of a full horizon is dropped unfolded.
    function testAnEntryReusedOnTheOtherSideIsDroppedOnEviction() public {
        _reuseOnTheRedeemSide();
        h.contributeUnbatched(2, alice, true, 10);
        h.track(2, alice, 1);
        assertEq(h.ledger().redeemAssets, 0, "the redemption was not folded by the eviction");
        assertEq(h.recentOf(alice, true).length, 1, "only the new entry is left");
        assertEq(h.recentOf(alice, true)[0], 2);
    }

    /// @dev Alice's deposit id 1 is tracked, settled and folded out directly, so it retires with its horizon entry
    ///      left in place; the id then reopens on the redeem side and settles.
    function _reuseOnTheRedeemSide() internal {
        h.contributeUnbatched(1, alice, true, 100);
        h.track(1, alice, 4);
        h.flush(1);
        h.settle(1, 100, 1_000, 0);
        h.fold(1, alice);
        h.contributeUnbatched(1, alice, false, 50);
        h.flush(1);
        h.settleRedeem(1, 25, 50);
    }

    /// @dev A transfer moves only the unsettled remainder, so a deferred fold holds it: moving the contribution would
    ///      carry the sender's settled slice to the recipient. Once the fold goes through, it moves.
    function testATransferWaitsForADeferredFold() public {
        h.contribute(LID, alice, false, 1_000);
        h.flush(LID);
        h.settleRedeem(LID, 250, 500);
        h.remember(LID, alice);
        h.setLedger(3, MAX - 100);
        h.fold(LID, alice);

        vm.expectRevert(IVaultErrors.FoldDeferred.selector);
        h.transfer(LID, alice, bob);

        h.setLedger(3, 0);
        h.fold(LID, alice);
        h.transfer(LID, alice, bob);
        assertEq(h.ledger().redeemAssets, 250, "the settled slice stayed with the sender");
        assertEq(h.pendingTotal(bob, false), 500, "and only the remainder moved");
    }

    /// @dev Each counter a credit touches is held to the limit, on both sides: the filled leg's two and the refund.
    function testEveryCounterACreditTouchesIsHeldToTheLimit() public {
        // Deposit side: shares to mint, then the assets they were bought with
        h.contribute(1, alice, true, 1_000);
        h.flush(1);
        h.settle(1, 1_000, 2_000, 0);
        h.remember(1, alice);
        h.setLedger(0, MAX - 1_999);
        (,,,, bool done) = h.fold(1, alice);
        assertFalse(done, "maxMint has no room for 2,000");
        h.setLedger(0, 0);
        h.setLedger(1, MAX - 999);
        (,,,, done) = h.fold(1, alice);
        assertFalse(done, "depositAssets has no room for 1,000");
        h.setLedger(1, 0);
        (,,,, done) = h.fold(1, alice);
        assertTrue(done, "with room, it folds");

        // Redeem side: assets to withdraw, then the shares they were paid for
        h.contribute(2, bob, false, 1_000);
        h.flush(2);
        h.settleRedeem(2, 700, 1_000);
        h.remember(2, bob);
        h.setLedger(2, MAX - 699);
        (,,,, done) = h.fold(2, bob);
        assertFalse(done, "maxWithdraw has no room for 700");
        h.setLedger(2, 0);
        h.setLedger(3, MAX - 999);
        (,,,, done) = h.fold(2, bob);
        assertFalse(done, "redeemShares has no room for 1,000");
        h.setLedger(3, 0);
        (,,,, done) = h.fold(2, bob);
        assertTrue(done);

        // The refund counter of a cancellation
        h.contribute(4, carol, false, 1_000);
        h.flush(4);
        h.cancelRedeem(4, 1_000, 900);
        h.remember(4, carol);
        h.setLedger(4, MAX - 899);
        (,,,, done) = h.fold(4, carol);
        assertFalse(done, "refundShares has no room for 900");
        h.setLedger(4, 0);
        (,,,, done) = h.fold(4, carol);
        assertTrue(done);
        assertEq(h.ledger().refundShares, 900);
    }

    /// @dev The views promise what folding the horizon then credits, deferral included: a position that does not fit
    ///      is not offered, and its settled part stays pending, so a claim at the reported maximum is never short.
    function testTheViewLeavesOutWhatTheFoldWouldDefer() public {
        // alice holds two settled positions; the first fits the ledger and the second does not on top of it
        h.contribute(1, alice, false, 1_000);
        h.contribute(2, alice, false, 1_000);
        h.flush(1);
        h.flush(2);
        h.settleRedeem(1, 400, 600);
        h.settleRedeem(2, 400, 600);
        h.remember(1, alice);
        h.remember(2, alice);
        h.setLedger(3, MAX - 800); // room for one 600-share credit, not two

        UnfoldedState memory u = h.unfoldedOf(alice);
        assertEq(u.redeemShares, 600, "only the first is offered");
        assertEq(u.redeemAssets, 400);
        assertEq(u.redeemPending, 1_400, "the second stays wholly pending, with the first's unsettled part");

        InvestmentState memory before = h.ledger();
        h.foldRecent(alice);
        InvestmentState memory l = h.ledger();
        assertEq(l.redeemShares - before.redeemShares, u.redeemShares, "the fold credits what the view promised");
        assertEq(l.redeemAssets - before.redeemAssets, u.redeemAssets);
        assertEq(h.contributionOf(2, alice), 1_000, "the deferred one is still there");
    }

    /// @dev For any state near the limit, the view of the horizon and the fold of it agree, and neither reverts.
    function testFuzzTheViewAndTheFoldAgreeNearTheLimit(
        uint128 headroomA,
        uint128 headroomB,
        uint128 headroomC,
        uint128 fillA,
        uint128 fillB
    ) public {
        fillA = uint128(bound(fillA, 1, 1e30));
        fillB = uint128(bound(fillB, 1, 1e30));
        h.contribute(1, alice, false, fillA);
        h.contribute(2, alice, false, fillB);
        h.contribute(3, alice, true, fillA);
        h.flush(1);
        h.flush(2);
        h.flush(3);
        h.settleRedeem(1, fillA / 2 + 1, fillA);
        h.settleRedeem(2, fillB / 2 + 1, fillB);
        h.settle(3, fillA / 3 + 1, fillA, 0);
        h.remember(1, alice);
        h.remember(2, alice);
        h.remember(3, alice);
        h.setLedger(3, MAX - uint128(bound(headroomA, 0, 2e30)));
        h.setLedger(2, MAX - uint128(bound(headroomB, 0, 2e30)));
        h.setLedger(0, MAX - uint128(bound(headroomC, 0, 2e30)));

        UnfoldedState memory u = h.unfoldedOf(alice);
        InvestmentState memory before = h.ledger();
        h.foldRecent(alice);
        InvestmentState memory l = h.ledger();
        assertEq(l.redeemShares - before.redeemShares, u.redeemShares, "redeem shares");
        assertEq(l.redeemAssets - before.redeemAssets, u.redeemAssets, "redeem assets");
        assertEq(l.depositShares - before.depositShares, u.depositShares, "deposit shares");
        assertEq(l.depositAssets - before.depositAssets, u.depositAssets, "deposit assets");
    }

    /// @dev The same with cancellations in the mix, on both sides, and the refund counters at the top of their range
    ///      as well: a fill and a cancellation settled in one bucket, the cancellation's net refunded to the ledger.
    function testFuzzTheViewAndTheFoldAgreeWithCancellationsNearTheLimit(
        uint128 headroomA,
        uint128 headroomB,
        uint128 headroomC,
        uint128 headroomD,
        uint128 amount
    ) public {
        amount = uint128(bound(amount, 10, 1e30));
        h.contribute(1, alice, true, amount);
        h.contribute(2, alice, false, amount);
        h.contribute(3, bob, true, amount);
        h.flush(1);
        h.flush(2);
        h.flush(3);
        h.settle(1, amount / 4 + 1, amount / 2, amount / 4); // a fill and a cancellation of a deposit bucket
        h.settleRedeem(2, amount / 3 + 1, amount / 3);
        h.cancelRedeem(2, amount / 3, amount / 4);
        h.settleCancelled(3, amount, amount - amount / 10);
        h.remember(1, alice);
        h.remember(2, alice);
        h.remember(3, bob);
        h.setLedger(5, MAX - uint128(bound(headroomA, 0, 2e30))); // refundAssets
        h.setLedger(4, MAX - uint128(bound(headroomB, 0, 2e30))); // refundShares
        h.setLedger(0, MAX - uint128(bound(headroomC, 0, 2e30))); // maxMint
        h.setLedger(3, MAX - uint128(bound(headroomD, 0, 2e30))); // redeemShares

        UnfoldedState memory u = h.unfoldedOf(alice);
        InvestmentState memory before = h.ledger();
        h.foldRecent(alice);
        InvestmentState memory l = h.ledger();
        assertEq(l.refundAssets - before.refundAssets, u.refundAssets, "refund assets");
        assertEq(l.refundShares - before.refundShares, u.refundShares, "refund shares");
        assertEq(l.depositShares - before.depositShares, u.depositShares, "deposit shares");
        assertEq(l.depositAssets - before.depositAssets, u.depositAssets, "deposit assets");
        assertEq(l.redeemAssets - before.redeemAssets, u.redeemAssets, "redeem assets");
        assertEq(l.redeemShares - before.redeemShares, u.redeemShares, "redeem shares");
    }
}
