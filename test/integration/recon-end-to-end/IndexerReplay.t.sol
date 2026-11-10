// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CryticToFoundry} from "./CryticToFoundry.sol";
import {VaultIndexer} from "./mocks/VaultIndexer.sol";

import {IEscrow} from "../../../src/core/spoke/interfaces/IEscrow.sol";

import {IAsyncVault, Bucket, Contribution, REASON_REDEEM} from "../../../src/vaults/interfaces/IAsyncVault.sol";

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

/// @notice The vault rebuilt from its logs alone. A `VaultIndexer` consumes what the handlers' calls emitted, and
///         after every few calls the replay is compared with the vault: each bucket and contribution against its
///         view, each pending view against the closed form, each controller's claims, reservations and claimed
///         totals against the ledgers the suite keeps. The vault is then made to fold every position inside a
///         snapshot, which is the one state the claimable views can be read without the lazily derived slices, and
///         the indexer must reach it from the fold's own logs.
/// @dev    Foundry only: Echidna and Medusa cannot read logs. Each test starts the recording itself, so the logs of
///         `setUp` are not the indexer's.
contract IndexerReplayReachability is CryticToFoundry {
    VaultIndexer internal indexer;
    address[] internal followed;
    uint256 internal replays;
    uint256 internal accepted;
    uint256 internal discarded;
    /// @dev Pending views that counted a settlement their position had not folded yet
    uint256 internal lazyViews;

    //----------------------------------------------------------------------------------------------
    // Tests
    //----------------------------------------------------------------------------------------------

    /// @dev Random handler sequences, replayed every few calls and at the end.
    /// forge-config: default.fuzz.runs = 40
    function testFuzzIndexerReplay(uint256 seed) public {
        _arm();
        _fund();
        for (uint256 i; i < 48; i++) {
            _step(uint256(keccak256(abi.encode(seed, i))));
            if (i % 6 == 5) _replay();
        }
        _replay();
        assertProperties();
        _assertNoFailures();
    }

    /// @dev Every event kind the indexer follows is reached by the handlers, so a replay that agrees with the vault
    ///      cannot be one that saw nothing.
    function testEveryEventKindIsReached() public {
        _arm();
        _fund();
        for (uint256 i; i < 240; i++) {
            _step(uint256(keccak256(abi.encode("reach", i))));
            if (i % 20 == 19) _replay();
        }
        _replay();
        assertGt(accepted, 0, "no step was clean");
        console.log("clean / discarded steps", accepted, discarded);

        string[20] memory names = [
            "DepositRequest/RedeemRequest",
            "BucketOpened",
            "RequestFlushed",
            "BucketSettled",
            "escrow DecreaseReserve releasing a settled deposit",
            "escrow IncreaseReserve of a settlement's payout",
            "RequestFolded",
            "RequestFolded completed",
            "RequestFolded retired",
            "RequestFolded slice of a shared bucket",
            "DepositClaimable",
            "RedeemClaimable",
            "CancelDepositClaimable",
            "CancelRedeemClaimable",
            "RequestTransferred",
            "Claimed",
            "Claimed with a refund",
            "InstantFees",
            "ForwardedToRoute",
            "ERC-4626 Deposit/Withdraw"
        ];
        for (uint256 k; k < names.length; k++) {
            assertGt(indexer.seen(k), 0, string.concat("unreachable: ", names[k]));
        }
        assertGt(replays, 0, "no replay ran");
        assertGt(lazyViews, 0, "no pending view was ahead of its last fold");
    }

    /// @dev A manager that takes part of a deposit's reservation back before the approval leaves the approval to release
    ///      what is left. That clamped release is visible only in the escrow's `DecreaseReserve` under the request's
    ///      reason: the early unreserve is no event of the vault, so the reservation the vault's logs alone replay is
    ///      now higher than the escrow's, and only the escrow's log says what the approval released.
    function testAnEarlyUnreserveShowsOnlyInTheEscrowsRelease() public {
        _arm();
        vault_requestDeposit(0, 0, 0, 100 * ONE_ASSET);
        Req memory r = reqs[reqs.length - 1];
        address vault = address(vaults[0]);
        bytes32 reason = _depositReason(uint96(r.requestId));
        (bool unreserved,) = _callAs(
            BSM,
            address(spoke),
            abi.encodeCall(spoke.unreserve, (poolA, scA, address(usdc), 0, uint128(40 * ONE_ASSET), vault, reason))
        );
        assertTrue(unreserved, "the manager could not unreserve");

        IEscrow escrow = _escrow(poolA);
        uint256 reservedBefore = escrow.reservedBy(scA, vault, reason, address(usdc), 0);
        hub_fulfill(reqs.length - 1, 0, true);
        uint256 reservedAfter = escrow.reservedBy(scA, vault, reason, address(usdc), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        indexer.consume(logs);
        _assertNoAnomalies("the replay of an approval after an early unreserve");

        // The last release under the request's reason is the approval's, after the manager's
        uint128 released;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(escrow) || logs[i].topics[0] != IEscrow.DecreaseReserve.selector) continue;
            (, address caller, bytes32 reason_, uint128 delta,) =
                abi.decode(logs[i].data, (bytes16, address, bytes32, uint128, uint128));
            if (caller == vault && reason_ == reason) released = delta;
        }
        assertEq(reservedBefore, 60 * ONE_ASSET, "the early unreserve did not take effect");
        assertEq(released, reservedBefore - reservedAfter, "the escrow's DecreaseReserve != the approval's release");
        assertEq(
            indexer.approvedOf(vault, r.requestId),
            reservedBefore - reservedAfter,
            "the replayed approval != the escrow's release"
        );
        assertGt(
            indexer.reservedDepositOf(vault, r.requestId),
            reservedAfter,
            "the logs alone replayed the reservation the spoke changed"
        );
    }

    /// @dev A position transferred after a part fill moves its whole contribution and the part still pending, and the
    ///      event says both.
    function testATransferAfterAPartFillReportsWhatIsPending() public {
        _arm();
        vault_requestDeposit(1, 2, 0, 700 * ONE_ASSET);
        hub_fulfill(reqs.length - 1, 200 * ONE_ASSET, false);
        vault_transferRequest(reqs.length - 1, 2, 0);
        _replay();
        assertGt(indexer.seen(uint256(VaultIndexer.Kind.Transferred)), 0, "unreachable: a transfer after a part fill");
    }

    //----------------------------------------------------------------------------------------------
    // Driving
    //----------------------------------------------------------------------------------------------

    function _arm() internal {
        indexer = new VaultIndexer();
        for (uint256 v; v < vaults.length; v++) {
            _follow(address(vaults[v]));
        }
        _follow(address(vaultB));
        _follow(address(vaultC));
        _follow(address(vaultD));
        _follow(address(vaultE));
        vm.recordLogs();
        // The state diff of a step and a replay cost more than a test's gas limit, and no check here reads gas
        vm.pauseGasMetering();
    }

    function _follow(address vault) internal {
        indexer.register(vault);
        followed.push(vault);
    }

    /// @dev Every actor holds shares, so redemptions have something to request.
    function _fund() internal {
        for (uint256 a; a < 3; a++) {
            _step(type(uint256).max - a);
        }
    }

    /// @dev One handler call, taken only if it is clean. The recorded logs include the ones a reverted frame emitted
    ///      before it reverted, which no indexer would ever see, and a handler swallows reverts all the time (a refused
    ///      fill, a claim past the maximum). A call in which a followed vault reverted anywhere is rolled back whole,
    ///      so what the indexer consumes is exactly what happened.
    function _step(uint256 r) internal {
        uint256 snapshot = vm.snapshotState();
        (bool clean, Vm.Log[] memory logs) = this.recordedStep(r);
        if (clean) {
            vm.deleteStateSnapshot(snapshot);
            indexer.consume(logs);
            accepted++;
        } else {
            vm.revertToStateAndDelete(snapshot);
            discarded++;
        }
    }

    /// @dev Its own call frame, so the memory the state diff takes is returned with it.
    function recordedStep(uint256 r) external returns (bool clean, Vm.Log[] memory logs) {
        vm.getRecordedLogs();
        vm.startStateDiffRecording();
        _dispatch(r);
        clean = !_aVaultReverted(vm.stopAndReturnStateDiff());
        logs = vm.getRecordedLogs();
        _assertNoFailures();
    }

    /// @dev Whether a call into a followed vault reverted, in itself or in a call above it.
    function _aVaultReverted(VmSafe.AccountAccess[] memory accesses) internal view returns (bool) {
        for (uint256 i; i < accesses.length; i++) {
            if (
                accesses[i].reverted && accesses[i].kind == VmSafe.AccountAccessKind.Call
                    && indexer.isVault(accesses[i].account)
            ) {
                return true;
            }
        }
        return false;
    }

    /// @dev One handler call chosen and fed from `r`; a value near the top of the range is a funding deposit.
    function _dispatch(uint256 r) internal {
        if (r > type(uint256).max - 3) {
            flow_deposit(type(uint256).max - r, 0, 2_000 * ONE_ASSET, type(uint256).max - r);
            return;
        }
        uint256 a = uint256(keccak256(abi.encode(r, 1)));
        uint256 b = uint256(keccak256(abi.encode(r, 2)));
        uint256 c = uint256(keccak256(abi.encode(r, 3)));
        uint256 d = uint256(keccak256(abi.encode(r, 4)));
        bool flag = d % 2 == 0;
        uint256 kind = r % 64;

        if (kind < 8) vault_requestDeposit(a, b, c, d);
        else if (kind < 14) vault_requestRedeem(a, b, c, d);
        else if (kind < 18) _pushAndTransfer(a, b, c, d, flag);
        else if (kind < 21) vault_flush(a);
        else if (kind < 24) vault_fold(a, b);
        else if (kind < 27) vault_foldRequest(a);
        else if (kind < 31) hub_fulfill(a, b, flag);
        else if (kind < 34) hub_cancel(a, b, flag);
        else if (kind < 37) vault_claimDeposit(a, b, c, flag);
        else if (kind < 40) vault_claimRedeem(a, b, c, flag);
        else if (kind < 43) vault_claimMax(a, b, flag);
        else if (kind < 46) vault_instantDeposit(a, flag, c, d % 4 == 0);
        else if (kind < 49) vault_instantRedeem(a, flag, c, d % 4 == 0);
        else if (kind < 51) flow_deposit(a, b, c, d);
        else if (kind < 53) flow_redeem(a, b, c, d);
        else if (kind < 55) flow_cancel(a, b, c, d, flag);
        else if (kind < 58) flow_sharedWindow(a, b, flag);
        else if (kind < 61) hub_warp(a % 2 days);
        else if (kind < 62) hub_setFee(uint16(a), flag);
        else if (kind < 63) vault_operatorClaim(a, b, c, flag);
        else router_deposit(a, b, c);
    }

    /// @dev A request made for another controller, which that controller then moves to a third.
    function _pushAndTransfer(uint256 a, uint256 b, uint256 c, uint256 d, bool isDeposit) internal {
        if (isDeposit) vault_requestDeposit(a, b, c, d);
        else vault_requestRedeem(a, b, c, d);
        if (reqs.length != 0) vault_transferRequest(reqs.length - 1, b, c);
    }

    function _drain() internal {
        indexer.consume(vm.getRecordedLogs());
    }

    //----------------------------------------------------------------------------------------------
    // Replay
    //----------------------------------------------------------------------------------------------

    /// @dev Its own call frame, so the memory the comparisons allocate is returned after each replay.
    function _replay() internal {
        this.replayLogs();
        replays++;
    }

    function replayLogs() external {
        _drain();
        _assertNoAnomalies("the replay of the handlers' logs");
        for (uint256 i; i < followed.length; i++) {
            _compareStored(followed[i]);
        }

        // The fold of every position happens in a snapshot: the indexer reaches the folded state from the fold's own
        // logs, and both are discarded together so the suite's ghosts never see the folds
        uint256 snapshot = vm.snapshotState();
        vm.startStateDiffRecording();
        for (uint256 i; i < followed.length; i++) {
            _foldEverything(followed[i]);
        }
        assertFalse(_aVaultReverted(vm.stopAndReturnStateDiff()), "a fold of a position reverted");
        _drain();
        _assertNoAnomalies("the replay of a fold of every position");
        for (uint256 i; i < followed.length; i++) {
            _compareFolded(followed[i]);
        }
        vm.revertToStateAndDelete(snapshot);
        assertEq(vm.getRecordedLogs().length, 0, "the revert left logs recorded");
    }

    function _assertNoAnomalies(string memory when_) internal view {
        if (indexer.anomalyCount() == 0) return;
        VaultIndexer.Anomaly memory a = indexer.anomaly(0);
        revert(string.concat(when_, ": ", a.what, " (got ", vm.toString(a.got), ", replay ", vm.toString(a.want), ")"));
    }

    /// @dev The controllers a check walks: every actor, and every other controller the logs named.
    function _controllersOf(address vault) internal view returns (address[] memory all) {
        address[] memory named = indexer.controllers(vault);
        all = new address[](actors.length + named.length);
        uint256 n;
        for (uint256 i; i < actors.length; i++) {
            all[n++] = actors[i];
        }
        for (uint256 i; i < named.length; i++) {
            bool listed;
            for (uint256 j; j < actors.length; j++) {
                if (named[i] == actors[j]) listed = true;
            }
            if (!listed) all[n++] = named[i];
        }
        assembly {
            mstore(all, n)
        }
    }

    function _foldEverything(address vault) internal {
        uint256[] memory ids = indexer.requestIds(vault);
        for (uint256 i; i < ids.length; i++) {
            address[] memory holders = indexer.holders(vault, ids[i]);
            for (uint256 h; h < holders.length; h++) {
                if (indexer.position(vault, ids[i], holders[h]).amount == 0) continue;
                IAsyncVault(vault).foldRequest(uint96(ids[i]), holders[h]);
            }
        }
    }

    //----------------------------------------------------------------------------------------------
    // Stored state: what the vault holds without any fold
    //----------------------------------------------------------------------------------------------

    function _compareStored(address vault) internal {
        uint256[] memory ids = indexer.requestIds(vault);
        address[] memory all = _controllersOf(vault);
        for (uint256 i; i < ids.length; i++) {
            _compareBucket(vault, ids[i]);
            for (uint256 c; c < all.length; c++) {
                _comparePosition(vault, ids[i], all[c]);
            }
        }
        for (uint256 c; c < all.length; c++) {
            _compareClaimableBounds(vault, all[c]);
            _compareClaimed(vault, all[c]);
        }
        _compareReservations(vault, ids);
        _compareOffers(vault);
    }

    function _compareBucket(address vault, uint256 requestId) internal view {
        uint96 localId = uint96(requestId);
        Bucket memory b = IAsyncVault(vault).bucket(localId);
        VaultIndexer.Bucket memory i = indexer.bucketOf(vault, requestId);
        assertEq(i.total, b.total, "bucket total != the replay's");
        assertEq(i.queued, b.queued, "bucket queued != the replay's");
        assertEq(i.fulfilledAssets, b.fulfilledAssets, "bucket fulfilledAssets != the replay's");
        assertEq(i.fulfilledShares, b.fulfilledShares, "bucket fulfilledShares != the replay's");
        assertEq(i.cancelledGross, b.cancelledGross, "bucket cancelledGross != the replay's");
        assertEq(i.cancelledNet, b.cancelledNet, "bucket cancelledNet != the replay's");
        assertEq(i.settlements, b.settlements, "bucket settlements != the replay's");
        assertEq(i.flushed, b.flushed, "bucket flushed != the replay's");
        if (b.total != 0) {
            assertEq(i.isDeposit, b.isDeposit, "bucket side != the replay's");
            assertEq(uint256(i.sent) + i.queued, b.total, "flushed plus queued != total in the replay");
        }
    }

    function _comparePosition(address vault, uint256 requestId, address controller) internal {
        uint96 localId = uint96(requestId);
        Contribution memory c = IAsyncVault(vault).contribution(localId, controller);
        VaultIndexer.Position memory p = indexer.position(vault, requestId, controller);
        assertEq(p.amount, c.amount, "contribution amount != the replay's");
        assertEq(p.foldedSettlements, c.foldedSettlements, "foldedSettlements != the replay's");
        assertEq(p.foldedAssets, c.foldedAssets, "foldedAssets != the replay's");
        assertEq(p.foldedShares, c.foldedShares, "foldedShares != the replay's");
        assertEq(p.foldedCancelledGross, c.foldedCancelledGross, "foldedCancelledGross != the replay's");
        assertEq(p.foldedCancelledNet, c.foldedCancelledNet, "foldedCancelledNet != the replay's");

        // The view answers the pending as of the last fold outside the controller's horizon and the closed form inside
        // it; the other side's view of the id reads zero
        VaultIndexer.Bucket memory b = indexer.bucketOf(vault, requestId);
        uint256 shown = b.isDeposit
            ? IAsyncVault(vault).pendingDepositRequest(requestId, controller)
            : IAsyncVault(vault).pendingRedeemRequest(requestId, controller);
        uint256 atFold = indexer.pendingAtFold(vault, requestId, controller);
        uint256 now_ = indexer.pendingNow(vault, requestId, controller);
        assertTrue(shown == atFold || shown == now_, "the pending view is neither the folded nor the closed-form one");
        if (shown != atFold) lazyViews++;
        if (b.total != 0) {
            uint256 other = b.isDeposit
                ? IAsyncVault(vault).pendingRedeemRequest(requestId, controller)
                : IAsyncVault(vault).pendingDepositRequest(requestId, controller);
            assertEq(other, 0, "the other side's pending view of a request id is not zero");
        }
    }

    /// @dev Before the folds, a controller's claimable is what its ledger holds plus at most what the unfolded
    ///      slices would add.
    function _compareClaimableBounds(address vault, address controller) internal view {
        VaultIndexer.Ledger memory l = indexer.ledgerOf(vault, controller);
        VaultIndexer.Unfolded memory u = indexer.unfolded(vault, controller);
        uint256 mint_ = IAsyncVault(vault).claimableMint(controller);
        uint256 withdraw_ = IAsyncVault(vault).claimableWithdraw(controller);
        assertGe(mint_, uint256(l.maxMint) + l.refundShares, "claimable shares below the replayed ledger");
        assertLe(mint_, uint256(l.maxMint) + l.refundShares + u.mintable, "claimable shares above ledger plus unfolded");
        assertGe(withdraw_, uint256(l.maxWithdraw) + l.refundAssets, "claimable assets below the replayed ledger");
        assertLe(
            withdraw_,
            uint256(l.maxWithdraw) + l.refundAssets + u.withdrawable,
            "claimable assets above ledger plus unfolded"
        );
    }

    function _compareClaimed(address vault, address controller) internal view {
        VaultIndexer.Ledger memory l = indexer.ledgerOf(vault, controller);
        assertEq(l.claimedShares, ghost_actorSharesClaimed[vault][controller], "claimed shares != the ghost ledger");
        assertEq(l.claimedAssets, ghost_actorAssetsClaimed[vault][controller], "claimed assets != the ghost ledger");
    }

    /// @dev A deposit's reservation per bucket, and the redeem payout reservation per vault, as the logs say they
    ///      moved.
    function _compareReservations(address vault, uint256[] memory ids) internal view {
        IAsyncVault v = IAsyncVault(vault);
        IEscrow escrow = IEscrow(v.escrow());
        address asset_ = v.asset();
        for (uint256 i; i < ids.length; i++) {
            uint96 localId = uint96(ids[i]);
            assertEq(
                indexer.reservedDepositOf(vault, ids[i]),
                escrow.reservedBy(v.scId(), vault, _depositReason(localId), asset_, 0),
                "a deposit reservation != the replay's"
            );
        }
        assertEq(
            indexer.reservedRedeem(vault),
            escrow.reservedBy(v.scId(), vault, REASON_REDEEM, asset_, 0),
            "the redeem reservation != the replay's"
        );
    }

    /// @dev A vault with a liquidity route offered it every released approval and every instant deposit's escrow, and a
    ///      vault without one offered nothing.
    function _compareOffers(address vault) internal view {
        uint256 want = address(IAsyncVault(vault).liquidityRoute()) == address(0) ? 0 : indexer.expectedOffer(vault);
        assertEq(indexer.offered(vault), want, "ForwardedToRoute != the released approvals and instant deposits");
    }

    //----------------------------------------------------------------------------------------------
    // Folded state: every position folded, so the views carry no lazily derived part
    //----------------------------------------------------------------------------------------------

    function _compareFolded(address vault) internal {
        address[] memory all = _controllersOf(vault);
        uint256[] memory ids = indexer.requestIds(vault);
        for (uint256 c; c < all.length; c++) {
            _compareLedger(vault, all[c]);
            _comparePendingTotals(vault, all[c], ids);
        }
        for (uint256 i; i < ids.length; i++) {
            _compareBucket(vault, ids[i]);
            for (uint256 c; c < all.length; c++) {
                _comparePosition(vault, ids[i], all[c]);
            }
        }
    }

    function _compareLedger(address vault, address controller) internal view {
        IAsyncVault v = IAsyncVault(vault);
        VaultIndexer.Ledger memory l = indexer.ledgerOf(vault, controller);
        assertEq(
            v.claimableMint(controller), uint256(l.maxMint) + l.refundShares, "claimableMint != the replayed ledger"
        );
        assertEq(
            v.claimableWithdraw(controller),
            uint256(l.maxWithdraw) + l.refundAssets,
            "claimableWithdraw != the replayed ledger"
        );
        assertEq(v.claimableDepositRequest(0, controller), l.depositAssets, "claimable deposit assets != the replay's");
        assertEq(v.claimableRedeemRequest(0, controller), l.redeemShares, "claimable redeem shares != the replay's");
    }

    function _comparePendingTotals(address vault, address controller, uint256[] memory ids) internal view {
        uint256 deposits;
        uint256 redeems;
        for (uint256 i; i < ids.length; i++) {
            uint256 pending = indexer.pendingNow(vault, ids[i], controller);
            if (indexer.bucketOf(vault, ids[i]).isDeposit) deposits += pending;
            else redeems += pending;
        }
        assertEq(IAsyncVault(vault).pendingDepositRequest(0, controller), deposits, "pending deposits != the replay's");
        assertEq(IAsyncVault(vault).pendingRedeemRequest(0, controller), redeems, "pending redeems != the replay's");
    }
}
