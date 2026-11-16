// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GapTargets} from "./GapTargets.sol";
import {ExitTargets} from "./ExitTargets.sol";
import {ProRataTargets} from "./ProRataTargets.sol";

import {RequestId} from "../../../../src/core/types/RequestId.sol";

import {IAsyncVault} from "../../../../src/vaults/interfaces/IAsyncVault.sol";

import {vm} from "@chimera/Hevm.sol";

/// @notice What a contributor is owed does not depend on the order or the timing of the permissionless steps around
///         the hub's fills, and the rescue still completes after the pool re-terms its policies.
/// @dev    Order independence. A scenario is built twice or thrice from the same seeds, each time in a call that
///         reverts with its figures (so the runs share a starting state and leave no trace), and the figures are
///         compared outside. Time is a cheatcode and survives the revert, so it is put back before every run.
///           - `flow_foldClaimOrder`: a controller holds a slice in each of two settled windows. Folding both and then
///             claiming, claiming first (which folds its recent windows) and folding after, and folding one window,
///             claiming a part, folding the other and claiming the rest all end with the same balances, the same
///             escrow and nothing left owed. The last claim takes every unit still owed, so a part claimed on the way
///             cannot change the total.
///           - `flow_flushTimingIndependence`: a window is flushed right after it closes by a stranger, by a
///             contributor, or late (by the next window's first request, or several periods on); the hub fills it
///             the same way, and every contributor's claimable, pending and final balances are the same.
///         Whatever precondition is not met (a membership that lapsed, a fill the hub refuses, an escrow reserved past
///         its balance, a contributor with a position already) leaves the scenario unchecked rather than failed.
///
///         Liveness across policy changes. A request policy is fixed per vault, so what the pool can change under
///         open requests is the instant lane's terms, the hub policy, the request observer and the fill fee.
///         `exit_afterPolicySwap` re-terms the instant lane and changes one of the other three, requires every open
///         request to read the same, and runs the rescue.
abstract contract OrderIndependenceTargets is GapTargets, ProRataTargets, ExitTargets {
    uint256 internal constant ORDER_VARIANTS = 3;
    uint8 internal constant KIND_FOLD_CLAIM = 0;
    uint8 internal constant KIND_FLUSH_TIMING = 1;
    /// @dev How many open requests the swap handler compares before and after, to stay inside the gas of one call.
    uint256 internal constant SWAP_WATCHED = 8;

    /// @dev Thrown at the end of every scenario run: whether it ran to its figures, whether a check failed inside it
    ///      (Foundry discards what the revert unwinds), and the figures.
    error OrderScenarioEnded(bool valid, bool failed, uint256[] figures);
    error NotSelf();

    /// @dev A scenario's windows and contributors, in memory to stay clear of the stack limit.
    struct Order {
        IAsyncVault vault;
        uint8 v;
        bool isDeposit;
        uint256 seed;
        uint256 n;
        address[3] who;
        /// @dev Per contributor, what it requests in each of the two windows.
        uint256[2][3] amount;
        Req[2] r;
        uint256[2] total;
    }

    //----------------------------------------------------------------------------------------------
    // Handlers
    //----------------------------------------------------------------------------------------------

    function flow_foldClaimOrder(
        uint256 actorSeed,
        uint256 vaultSeed,
        uint256 amountSeed,
        uint256 fillSeed,
        bool isDeposit
    ) public {
        if (_orderCompare(KIND_FOLD_CLAIM, [actorSeed, vaultSeed, amountSeed, fillSeed], isDeposit)) {
            _ok("flow_foldClaimOrder");
        }
    }

    function flow_flushTimingIndependence(
        uint256 actorSeed,
        uint256 vaultSeed,
        uint256 amountSeed,
        uint256 fillSeed,
        bool isDeposit
    ) public {
        if (_orderCompare(KIND_FLUSH_TIMING, [actorSeed, vaultSeed, amountSeed, fillSeed], isDeposit)) {
            _ok("flow_flushTimingIndependence");
        }
    }

    /// @dev Stateless, like `exit_everyoneCanLeave`: the pool re-terms its policies under whatever the fuzzer left
    ///      open, every open request must read as before, and the rescue must still take everyone out.
    function exit_afterPolicySwap(uint256 seed, uint256 swapSeed) public {
        uint256 failuresBefore = _failureCount();
        uint256 timeBefore = block.timestamp;
        _afterPolicySwap(seed, swapSeed);
        if (_failureCount() != failuresBefore) return;
        vm.warp(timeBefore);
        revert ExitRehearsalEnded();
    }

    //----------------------------------------------------------------------------------------------
    // Order independence: running and comparing
    //----------------------------------------------------------------------------------------------

    function _orderCompare(uint8 kind, uint256[4] memory seeds, bool isDeposit) internal returns (bool) {
        uint256 timeBefore = block.timestamp;
        uint256[][ORDER_VARIANTS] memory runs;
        for (uint8 variant; variant < ORDER_VARIANTS; variant++) {
            (bool valid, bool failed, uint256[] memory figures) = _orderCall(kind, variant, seeds, isDeposit);
            vm.warp(timeBefore);
            t(!failed, "a check failed inside an order independence scenario");
            if (!valid || failed) return false;
            runs[variant] = figures;
        }
        for (uint256 variant = 1; variant < ORDER_VARIANTS; variant++) {
            eq(runs[variant].length, runs[0].length, "the runs of a scenario made different figures");
            for (uint256 i; i < runs[0].length && i < runs[variant].length; i++) {
                eq(
                    runs[variant][i],
                    runs[0][i],
                    kind == KIND_FOLD_CLAIM
                        ? "folding and claiming in another order changed what a controller ends with"
                        : "flushing a window at another time or by another caller changed an entitlement"
                );
            }
        }
        return true;
    }

    function _orderCall(uint8 kind, uint8 variant, uint256[4] memory seeds, bool isDeposit)
        internal
        returns (bool valid, bool failed, uint256[] memory figures)
    {
        try this.orderRun(kind, variant, seeds, isDeposit) {}
        catch (bytes memory err) {
            if (err.length >= 4 && bytes4(err) == PANIC) {
                // A failed check under Echidna or Medusa is an `assert`, and any other panic is a bug in the scenario:
                // neither is an infeasible scenario to drop.
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
            if (err.length < 4 || bytes4(err) != OrderScenarioEnded.selector) return (false, false, figures);
            assembly {
                mstore(add(err, 4), sub(mload(err), 4))
                err := add(err, 4)
            }
            (valid, failed, figures) = abi.decode(err, (bool, bool, uint256[]));
        }
    }

    /// @dev Public for the self-call that gives a run its own revert; nobody else may call it.
    function orderRun(uint8 kind, uint8 variant, uint256[4] memory seeds, bool isDeposit) public {
        require(msg.sender == address(this), NotSelf());
        siblingBudget = 0;
        uint256 failuresBefore = _failureCount();
        Order memory s;
        s.isDeposit = isDeposit;
        s.seed = seeds[3];
        uint256[] memory figures;
        bool valid = _orderOpen(s, seeds[0], seeds[1], seeds[2]);
        if (valid) {
            (valid, figures) = kind == KIND_FOLD_CLAIM ? _orderFoldClaim(s, variant) : _orderFlushTiming(s, variant);
        }
        revert OrderScenarioEnded(valid, _failureCount() != failuresBefore, figures);
    }

    //----------------------------------------------------------------------------------------------
    // Order independence: scenario setup
    //----------------------------------------------------------------------------------------------

    /// @dev Picks the contributors, which all start clean in the vault, and their amounts for the two windows.
    function _orderOpen(Order memory s, uint256 actorSeed, uint256 vaultSeed, uint256 amountSeed)
        internal
        returns (bool)
    {
        s.v = vaultSeed % 2 == 0 ? 1 : 4;
        s.vault = vaults[s.v];
        if (_overReserved() || !_pricesLive() || !_sharedFillBuys(s.isDeposit)) return false;
        actorSeed %= 2 ** 128;
        uint128 dust = _dust(s.isDeposit);
        uint256 want = 2 + amountSeed / 8 % 2;
        for (uint256 i; i < actors.length && s.n < want; i++) {
            address a = actors[(actorSeed + i) % actors.length];
            uint256 balance = s.isDeposit ? usdc.balanceOf(a) : shareA.balanceOf(a);
            if (frozen[a] || !_healthy(s.vault, a) || _hasPositionIn(s.vault, a) || balance < 2 * dust) continue;
            s.who[s.n++] = a;
        }
        if (s.n < 2) return false;

        Shared memory sizing;
        sizing.isDeposit = s.isDeposit;
        sizing.n = 2 * s.n;
        uint256 cap = _sharedCap(sizing);
        if (cap < dust) return false;
        for (uint256 i; i < s.n; i++) {
            uint256 balance = s.isDeposit ? usdc.balanceOf(s.who[i]) : shareA.balanceOf(s.who[i]);
            uint256 most = _min(balance / 2, cap);
            for (uint256 w; w < 2; w++) {
                s.amount[i][w] = between(uint256(keccak256(abi.encode(amountSeed, i, w))), dust, most);
            }
        }
        return true;
    }

    /// @dev Every contributor requests its amount for window `w`; they must all land in one bucket. The calls go
    ///      straight to the vault, without the bookkeeping of the single-step handlers, which a run that is thrown away
    ///      has no use for and which would not fit the gas of one call.
    function _orderRequests(Order memory s, uint256 w) internal returns (bool) {
        s.total[w] = 0;
        for (uint256 i; i < s.n; i++) {
            address a = s.who[i];
            uint256 amount = s.amount[i][w];
            vm.prank(a);
            usdc.approve(address(s.vault), amount);
            (bool requested, bytes memory ret) = _callAs(
                a,
                address(s.vault),
                abi.encodeWithSignature(
                    s.isDeposit ? "requestDeposit(uint256,address,address)" : "requestRedeem(uint256,address,address)",
                    amount,
                    a,
                    a
                )
            );
            if (!requested) return false;
            uint256 id = abi.decode(ret, (uint256));
            if (i == 0) s.r[w] = Req(s.v, id, s.isDeposit);
            else if (id != s.r[w].requestId) return false;
            if (s.vault.contribution(uint96(s.r[w].requestId), a).amount != amount) return false;
            s.total[w] += amount;
        }
        return true;
    }

    /// @dev A fill of `fill` at the hub's prices, as the pool's fee manager makes it.
    function _orderFulfill(Order memory s, uint256 w, uint256 fill) internal returns (bool success) {
        (success,) = _callAs(
            FM,
            address(feeRequestManager),
            abi.encodeCall(
                feeRequestManager.fulfill,
                (poolA, scA, usdcId, RequestId.wrap(s.r[w].requestId), s.isDeposit, uint128(fill), 0, REFUND)
            )
        );
    }

    function _nextPeriod() internal {
        vm.warp((block.timestamp / PERIOD + 1) * PERIOD);
    }

    /// @dev Both windows are flushed, in full at the hub, and filled: each in one fill or a part and the rest, by seed.
    function _orderFill(Order memory s, uint256 windows) internal returns (bool) {
        for (uint256 w; w < windows; w++) {
            Req memory r = s.r[w];
            if (!_flushQueued(r) || _outstanding(r) != s.total[w]) return false;
        }
        uint128 dust = _dust(s.isDeposit);
        for (uint256 w; w < windows; w++) {
            if (!_pricesLive()) return false;
            uint256 total = s.total[w];
            uint256 mode = s.seed / (3 + w) % 2;
            if (mode == 0 || total < 2 * dust) {
                if (!_orderFulfill(s, w, total)) return false;
            } else {
                uint256 first = between(s.seed / 5 + w, dust, total - dust);
                if (!_orderFulfill(s, w, first) || !_orderFulfill(s, w, total - first)) return false;
            }
        }
        return true;
    }

    /// @dev What the claims need: every contributor still a member, not frozen, and the escrow able to pay.
    function _orderCanClaim(Order memory s) internal view returns (bool) {
        if (_overReserved()) return false;
        for (uint256 i; i < s.n; i++) {
            if (frozen[s.who[i]] || !_healthy(s.vault, s.who[i])) return false;
        }
        return true;
    }

    //----------------------------------------------------------------------------------------------
    // Order independence: fold and claim
    //----------------------------------------------------------------------------------------------

    function _orderFoldClaim(Order memory s, uint8 variant) internal returns (bool, uint256[] memory figures) {
        if (!_orderRequests(s, 0)) return (false, figures);
        _nextPeriod();
        if (!_orderRequests(s, 1) || s.r[0].requestId == s.r[1].requestId) return (false, figures);
        _nextPeriod();
        if (!_orderFill(s, 2) || !_orderCanClaim(s)) return (false, figures);

        for (uint256 i; i < s.n; i++) {
            address a = s.who[i];
            // The first contributor takes the variant's route; the others fold, then claim
            if (i != 0 || variant == 0) {
                _orderFold(s, a, 0);
                _orderFold(s, a, 1);
                _orderClaim(s, a);
            } else if (variant == 1) {
                _orderClaim(s, a);
                _orderFold(s, a, 0);
                _orderFold(s, a, 1);
                _orderClaim(s, a);
            } else {
                _orderFold(s, a, 0);
                _orderClaimHalf(s, a);
                _orderFold(s, a, 1);
                _orderClaim(s, a);
            }
        }
        if (!_orderCanClaim(s)) return (false, figures);
        figures = new uint256[](_orderFigureCount(s));
        _orderFigures(s, figures, 0);
        return (true, figures);
    }

    function _orderFold(Order memory s, address a, uint256 w) internal {
        if (s.vault.contribution(uint96(s.r[w].requestId), a).amount != 0) {
            // A fold the vault refuses leaves the position for the claim to take in
            try s.vault.foldRequest(uint96(s.r[w].requestId), a) {} catch {}
        }
    }

    /// @dev Claims everything the controller's ledger holds on each side, which must go through: shares by `mint`,
    ///      assets by `withdraw`, whatever the other side of the request.
    function _orderClaim(Order memory s, address a) internal {
        _orderClaimOf(s, a, s.vault.claimableMint(a), true);
        _orderClaimOf(s, a, s.vault.claimableWithdraw(a), false);
    }

    function _orderClaimOf(Order memory s, address a, uint256 amount, bool shares) internal returns (bool success) {
        if (amount == 0) return false;
        (success,) = _callAs(
            a,
            address(s.vault),
            abi.encodeWithSignature(
                shares ? "mint(uint256,address,address)" : "withdraw(uint256,address,address)", amount, a, a
            )
        );
        t(success, "claiming everything a controller is owed reverted");
    }

    /// @dev A part of what the controller can take now, on the side its windows settled into.
    function _orderClaimHalf(Order memory s, address a) internal {
        uint256 max = s.isDeposit ? s.vault.claimableMint(a) : s.vault.claimableWithdraw(a);
        if (max < 2) return;
        _callAs(
            a,
            address(s.vault),
            abi.encodeWithSignature(
                s.isDeposit ? "mint(uint256,address,address)" : "withdraw(uint256,address,address)", max / 2, a, a
            )
        );
    }

    //----------------------------------------------------------------------------------------------
    // Order independence: flush timing
    //----------------------------------------------------------------------------------------------

    /// @dev Variant 0 flushes the first window right after it closes, by a stranger; 1 by a contributor; 2 late: by
    ///      the next window's first request, or several periods on, by a contributor. With a second window it is
    ///      opened in the period after the first, so the first is closed before it.
    function _orderFlushTiming(Order memory s, uint8 variant) internal returns (bool, uint256[] memory figures) {
        bool next = s.seed / 11 % 2 == 1;
        if (!_orderRequests(s, 0)) return (false, figures);
        _nextPeriod();
        if (variant == 0 && !_orderFlushBy(s, OUTSIDER)) return (false, figures);
        if (variant == 1 && !_orderFlushBy(s, s.who[0])) return (false, figures);
        if (variant == 2 && !next) {
            vm.warp(block.timestamp + (2 + s.seed / 13 % 5) * PERIOD);
            if (!_orderFlushBy(s, s.who[1])) return (false, figures);
        }
        uint256 windows = 1;
        if (next) {
            if (!_orderRequests(s, 1) || s.r[0].requestId == s.r[1].requestId) return (false, figures);
            windows = 2;
            _nextPeriod();
        }
        if (!_orderFill(s, windows)) return (false, figures);
        if (s.vault.bucket(uint96(s.r[0].requestId)).queued != 0) return (false, figures);
        if (!_orderCanClaim(s)) return (false, figures);

        figures = new uint256[](2 * _orderFigureCount(s));
        _orderFigures(s, figures, 0);
        for (uint256 i; i < s.n; i++) {
            _orderFold(s, s.who[i], 0);
            if (windows == 2) _orderFold(s, s.who[i], 1);
            _orderClaim(s, s.who[i]);
        }
        if (!_orderCanClaim(s)) return (false, figures);
        _orderFigures(s, figures, _orderFigureCount(s));
        return (true, figures);
    }

    /// @dev A closed window is flushable by anyone: the caller never decides whether it is sent.
    function _orderFlushBy(Order memory s, address caller) internal returns (bool flushed) {
        vm.prank(caller);
        try s.vault.flushRequest(uint96(s.r[0].requestId)) {
            flushed = true;
        } catch {}
        t(flushed, "a closed window could not be flushed by an arbitrary caller");
    }

    //----------------------------------------------------------------------------------------------
    // Order independence: figures
    //----------------------------------------------------------------------------------------------

    function _orderFigureCount(Order memory s) internal pure returns (uint256) {
        return 6 * s.n + 3;
    }

    /// @dev What each contributor holds and is owed, then the escrow's balances and the supply.
    function _orderFigures(Order memory s, uint256[] memory figures, uint256 at) internal view {
        for (uint256 i; i < s.n; i++) {
            address a = s.who[i];
            figures[at++] = s.vault.claimableMint(a);
            figures[at++] = s.vault.claimableWithdraw(a);
            figures[at++] = s.vault.pendingDepositRequest(0, a);
            figures[at++] = s.vault.pendingRedeemRequest(0, a);
            figures[at++] = shareA.balanceOf(a);
            figures[at++] = usdc.balanceOf(a);
        }
        address escrow = address(_escrow(poolA));
        figures[at++] = shareA.balanceOf(escrow);
        figures[at++] = usdc.balanceOf(escrow);
        figures[at++] = shareA.totalSupply();
    }

    //----------------------------------------------------------------------------------------------
    // Liveness across policy changes
    //----------------------------------------------------------------------------------------------

    function _afterPolicySwap(uint256 seed, uint256 swapSeed) internal returns (Rescue memory) {
        // The seed is added to indices, so one at the top of the range is kept clear of the overflow
        seed %= 2 ** 128;
        bytes32 before = _openRequestsFingerprint(seed);
        _swapPolicies(swapSeed);
        t(
            _openRequestsFingerprint(seed) == before,
            "a policy change moved what an open request reads or what a bucket holds"
        );
        return _everyoneCanLeave(seed);
    }

    /// @dev The instant lane re-termed on one instant vault (fees, whether redemptions are open, gates, the reserve),
    ///      and one of the hub policy installed, the fill fee moved or the request observer toggled. One of each kind
    ///      per call keeps the setup inside the gas the rescue leaves.
    function _swapPolicies(uint256 swapSeed) internal {
        policy_configure(swapSeed >> 64, uint16(swapSeed >> 16), swapSeed, swapSeed >> 32, (swapSeed >> 48) % 8 == 0);
        uint256 kind = (swapSeed >> 72) % 3;
        if (kind == 0) hub_installPolicy();
        else if (kind == 1) hub_setFee(uint16(swapSeed >> 8), swapSeed % 5 == 0);
        else hub_setObserver(swapSeed % 2 == 0);
    }

    /// @dev Every actor's pending and claimable on each vault, and the queue, bucket total and hub order of the open
    ///      requests the seed starts at, which a change of policy must leave as they were.
    function _openRequestsFingerprint(uint256 seed) internal view returns (bytes32 h) {
        for (uint256 v; v < vaults.length; v++) {
            for (uint256 a; a < actors.length; a++) {
                h = keccak256(
                    abi.encode(
                        h,
                        vaults[v].pendingDepositRequest(0, actors[a]),
                        vaults[v].pendingRedeemRequest(0, actors[a]),
                        vaults[v].claimableMint(actors[a]),
                        vaults[v].claimableWithdraw(actors[a])
                    )
                );
            }
        }
        uint256 n = reqs.length < SWAP_WATCHED ? reqs.length : SWAP_WATCHED;
        for (uint256 i; i < n; i++) {
            Req memory r = reqs[(seed + i) % reqs.length];
            IAsyncVault vault = vaults[r.vault];
            h = keccak256(
                abi.encode(
                    h,
                    vault.bucket(uint96(r.requestId)).queued,
                    vault.bucket(uint96(r.requestId)).total,
                    _outstanding(r)
                )
            );
        }
    }
}
