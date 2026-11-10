// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {FlowTargets} from "./FlowTargets.sol";

import {IEscrow} from "../../../../src/core/spoke/interfaces/IEscrow.sol";

import {IAsyncVault} from "../../../../src/vaults/interfaces/IAsyncVault.sol";

import {vm} from "@chimera/Hevm.sol";

/// @notice Liveness: from any state the fuzzer reached, a rescue lets every healthy investor leave with nothing stuck.
/// @dev    A stateless doomsday handler: it settles everything, claims everything and checks the end state, then reverts
///         with `ExitRehearsalEnded`, so the dozens of state changes it makes never pollute the sequence it ran in.
///         Every check runs before that revert. Under Echidna and Medusa a failed check is an `assert(false)` that
///         aborts the call at once; under Foundry it is recorded in storage, which the revert would discard, so the
///         handler returns instead of reverting when `_failureCount` moved and the invariant reports it.
///
///         The rescue, in order:
///           1. Every open bucket of every live vault is flushed (a per-period window is closed by moving to the
///              next period; nothing else moves time).
///           2. The hub fills every outstanding order of pool A in full, at the current prices; an order it cannot
///              fill is cancelled instead. Deposits go first or last by the seed, so the order is explored.
///           3. Every investor that can claim folds its slices and claims both sides to zero, the controller itself
///              calling, through the same claim helpers the flows use (which assert a full claim goes through).
///           4. Each such investor has nothing pending and nothing claimable on any vault the rescue could settle, the
///              escrow still covers what is reserved and owed, and the standing solvency properties hold again.
///           5. Where the instant lane is open, a holder can redeem at the reported `maxRedeem`.
///
///         Skips, each a rule of the protocol rather than a convenience:
///           - A frozen investor, or one whose membership lapsed (the share hook refuses `DepositClaim` and
///             `RedeemClaim` for it, so its position waits for the pool; a refund alone would still go through, but
///             what the hook refuses is judged by `_healthy`, not guessed here). SPECIFICATION: a claim pushed to a
///             clean address by a frozen or lapsed controller is refused.
///           - A vault the pool unlinked or whose manager role it withdrew (`vaultUnlinked`, `vaultRevoked`):
///             `VaultRequestRouter` refuses callbacks to an unlinked vault, so its settlements stall, and a vault
///             without its role cannot pay (SPECIFICATION: "In-flight settlements survive an unlink", "A linked vault
///             is a manager of its pool"). Requests of such a vault are neither settled nor judged.
///           - An escrow over-reserved by a manager: `withdrawReserved` needs every other reservation covered, so
///             redeem claims and the instant lane wait for the pool to fund the escrow (`_overReserved`).
///           - A fill the hub refuses (a fill that converts to nothing at a zero price, a dust fill, a fee past the
///             hub policy, cash not in the escrow for a redemption) is not a failure: the order is cancelled, which
///             is always in policy and needs no price. A cancellation is judged only where it must apply (the escrow
///             is not over-reserved: a deposit cancellation re-reserves its refund under the same cover check).
///           - An oracle that refuses the price closes the instant lane, so step 5 stands down; the async steps do
///             not depend on it.
///         The loops are bounded by gas (`EXIT_GAS_BUDGET`), not by count: a rescue that runs out of budget asserts
///         none of the end-state claims, since it did not reach the end state.
abstract contract ExitTargets is FlowTargets {
    /// @dev Thrown at the end of every rescue that found nothing wrong, so none of its state changes survive.
    error ExitRehearsalEnded();

    /// @dev Gas the settling and claiming loops may spend before the rescue gives up on completing. The checks after
    ///      them, and one call past the last budget test, come on top; the whole handler stays well under 12M.
    uint256 internal constant EXIT_GAS_BUDGET = 7_000_000;

    /// @dev What one rescue did, kept in memory to stay clear of the stack limit.
    struct Rescue {
        uint256 gas0;
        uint256 start;
        bool redeemsFirst;
        /// @dev The budget ran out: the end state was not reached, so it is not asserted.
        bool incomplete;
        /// @dev Vaults (bit `v`) whose orders or claims the rescue could not finish for a documented reason.
        uint256 blocked;
        uint256 filled;
        uint256 cancelled;
        uint256 exits;
        uint256 instantExits;
        bool completed;
    }

    /// @dev Under Foundry, how many checks have failed so far; Echidna and Medusa abort at the first, so zero.
    function _failureCount() internal view virtual returns (uint256) {
        return 0;
    }

    function exit_everyoneCanLeave(uint256 seed) public {
        uint256 failuresBefore = _failureCount();
        uint256 timeBefore = block.timestamp;
        _everyoneCanLeave(seed);
        // Foundry keeps a recorded failure only if the call does not revert
        if (_failureCount() != failuresBefore) return;
        // A cheatcode's clock is not part of the state a revert restores, and the rescue may have moved it
        vm.warp(timeBefore);
        revert ExitRehearsalEnded();
    }

    function _everyoneCanLeave(uint256 seed) internal returns (Rescue memory s) {
        siblingBudget = 0;
        s.gas0 = gasleft();
        s.start = seed;
        s.redeemsFirst = seed / 7 % 2 == 1;

        _exitFlush(s);
        _exitSettle(s);
        // A redemption filled ahead of the deposit that funds it, or a manager's reservation, leaves the escrow
        // over-reserved: redeem claims wait for the cover (SPECIFICATION row 214), so nothing past here is judged
        bool over = _overReserved();
        if (!s.incomplete && !over) _exitClaim(s);
        // The end state is judged only if the budget carried the rescue to it
        s.completed = !s.incomplete && !over;
        if (!s.completed) return s;
        _exitJudge(s);
        _exitInstant(s);
        _exitSolvent();
    }

    //----------------------------------------------------------------------------------------------
    // 1. Flush
    //----------------------------------------------------------------------------------------------

    /// @dev A bucket still holding a queue is pushed to the hub, closing its window first if the policy needs it.
    ///      A live vault's open queue is always sent (`vault_flushAnyKind` holds a flush to this too), so one that
    ///      is not is a failure; a window that is still open after the move to the next period stays out.
    function _exitFlush(Rescue memory s) internal {
        uint256 n = reqs.length;
        for (uint256 i; i < n; i++) {
            Req memory r = reqs[(s.start + i) % n];
            if (_exitRetired(r.vault) || vaults[r.vault].bucket(uint96(r.requestId)).queued == 0) continue;
            if (!_exitBudget(s)) return;
            if (!_isClosed(r)) vm.warp((block.timestamp / PERIOD + 1) * PERIOD);
            if (!_isClosed(r)) {
                s.blocked |= 1 << r.vault;
                continue;
            }
            bool flushed = _flush(r);
            t(flushed, "a closed bucket of a live vault could not be flushed");
            if (!flushed) s.blocked |= 1 << r.vault;
        }
    }

    //----------------------------------------------------------------------------------------------
    // 2. Settle
    //----------------------------------------------------------------------------------------------

    function _exitSettle(Rescue memory s) internal {
        for (uint256 pass; pass < 2; pass++) {
            bool isDeposit = (pass == 0) != s.redeemsFirst;
            uint256 n = reqs.length;
            for (uint256 i; i < n; i++) {
                Req memory r = reqs[(s.start + i) % n];
                if (r.isDeposit != isDeposit || _exitRetired(r.vault) || s.blocked >> r.vault & 1 == 1) continue;
                uint128 outstanding = _outstanding(r);
                if (outstanding == 0) continue;
                if (!_exitBudget(s)) return;
                _exitSettleOne(s, r, outstanding);
            }
        }
    }

    /// @dev The whole order at the current prices; if the hub refuses that, the whole order cancelled.
    function _exitSettleOne(Rescue memory s, Req memory r, uint128 outstanding) internal {
        if (_fulfill(r, outstanding)) {
            s.filled++;
        } else if (_cancel(r, outstanding)) {
            s.cancelled++;
        } else {
            // A cancellation applies unless the escrow lacks the cover to re-reserve its refund
            t(_overReserved(), "an order the hub could neither fill nor cancel");
            s.blocked |= 1 << r.vault;
            return;
        }
        eq(_outstanding(r), 0, "a settled order is still outstanding");
    }

    //----------------------------------------------------------------------------------------------
    // 3. Claim
    //----------------------------------------------------------------------------------------------

    function _exitClaim(Rescue memory s) internal {
        for (uint256 a; a < actors.length; a++) {
            for (uint256 v; v < vaults.length; v++) {
                if (!_exitCanClaim(s, v, actors[a])) continue;
                if (!_exitBudget(s)) return;
                _exitFold(v, actors[a]);
                // Seed 1 is a claim of everything on each side, which the claim helpers assert goes through
                if (_claimAll(vaults[v], actors[a], 1)) s.exits++;
            }
        }
    }

    /// @dev Folds every slice the controller has not taken in yet: a settled bucket outside its horizon is claimable
    ///      only once folded.
    function _exitFold(uint256 v, address actor) internal {
        for (uint256 i; i < reqs.length; i++) {
            Req memory r = reqs[i];
            if (r.vault != v || !_canFold(r, actor, true)) continue;
            _foldOne(r.vault, uint96(r.requestId), actor);
        }
    }

    /// @dev An investor the rescue can take to zero on a vault: not frozen, a member (the hook refuses the claim legs
    ///      otherwise), on a vault that is neither unlinked nor without its role, and one whose orders the rescue
    ///      finished.
    function _exitCanClaim(Rescue memory s, uint256 v, address actor) internal view returns (bool) {
        return !frozen[actor] && _healthy(vaults[v], actor) && s.blocked >> v & 1 == 0;
    }

    //----------------------------------------------------------------------------------------------
    // 4. Judge
    //----------------------------------------------------------------------------------------------

    /// @dev Nothing pending and nothing claimable for an investor that could claim, on a vault that was settled. Read
    ///      off the ledger views, which do not price a cancellation's refund at a settlement price it may not have.
    function _exitJudge(Rescue memory s) internal {
        for (uint256 a; a < actors.length; a++) {
            for (uint256 v; v < vaults.length; v++) {
                if (!_exitCanClaim(s, v, actors[a])) continue;
                IAsyncVault vault = vaults[v];
                address actor = actors[a];
                eq(vault.claimableMint(actor), 0, "an investor was left shares to claim after the exit");
                eq(vault.claimableWithdraw(actor), 0, "an investor was left assets to claim after the exit");
                eq(vault.pendingDepositRequest(0, actor), 0, "an investor was left a deposit pending after the exit");
                eq(vault.pendingRedeemRequest(0, actor), 0, "an investor was left a redemption pending after the exit");
            }
        }
    }

    /// @dev The escrow still covers what it reserves and owes, and the standing solvency properties hold in the end
    ///      state too: a claim that paid out of the wrong reservation, or a fill that credited more than it backed,
    ///      shows here even if no single claim noticed.
    function _exitSolvent() internal {
        IEscrow escrow = _escrow(poolA);
        (uint128 total, uint128 reserved) = escrow.holding(scA, address(usdc), 0);
        if (!_overReserved()) lte(reserved, total, "the escrow reserves more than it holds after the exit");
        gte(usdc.balanceOf(address(escrow)), total, "the escrow holds less than its holding records");
        property_sum_of_possible_account_balances_leq_escrow();
        property_escrowReservedSumConsistency();
        property_escrowBalanceMatchesHoldingTotal();
        property_sum_of_shares_received();
        property_sum_of_assets_received();
        property_claimableMatchesOwedLessClaimed();
        property_noValueStrandedInEscrow();
    }

    //----------------------------------------------------------------------------------------------
    // 5. Instant lane
    //----------------------------------------------------------------------------------------------

    /// @dev A holder redeems what the lane reports it can, as `vault_maxExecutes` does, but across every holder and
    ///      both instant vaults at the end of the rescue. The oracle must vouch for the price, the holder must have
    ///      nothing in the async lane (the two-argument call would claim instead), and the vault must be live.
    function _exitInstant(Rescue memory s) internal {
        if (!_oracleValid()) return;
        for (uint256 v = 2; v < 4; v++) {
            IAsyncVault vault = vaults[v];
            for (uint256 a; a < actors.length; a++) {
                address actor = actors[a];
                if (!_exitCanClaim(s, v, actor) || _inAsync(vault, actor, false)) continue;
                uint256 max = vault.maxRedeem(actor);
                if (max == 0) continue;
                t(_instant(vault, actor, max, false, false), "an instant redemption at the reported maximum reverted");
                s.instantExits++;
            }
        }
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    function _exitRetired(uint256 v) internal view returns (bool) {
        return vaultRevoked[address(vaults[v])] || vaultUnlinked[address(vaults[v])];
    }

    /// @dev Whether the rescue may start another step; once it may not, it stays out for good.
    function _exitBudget(Rescue memory s) internal view returns (bool) {
        if (s.gas0 - gasleft() > EXIT_GAS_BUDGET) s.incomplete = true;
        return !s.incomplete;
    }
}
