// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ConservationTargets} from "./ConservationTargets.sol";

import {D18, d18} from "../../../../src/misc/types/D18.sol";

import {IAsyncVault} from "../../../../src/vaults/interfaces/IAsyncVault.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";

/// @notice One controller with several requests in flight in one vault: the requests sit in different buckets (a window
///         each in the per-period vaults, a fresh bucket each in the per-request vault), the hub settles them in
///         another order than they were made, in full, in parts and by cancellation, the positions are folded some by
///         a keeper and some by the claim, and the controller then claims in several parts through every entrypoint.
/// @dev    The single-request flows prove a controller gets what one fill settled; nothing else made a controller hold
///         several settled positions at once and claim across them, where the claimable ledger sums fills made at
///         different prices and the claim converts pro-rata over the sum. The controller starts with nothing anywhere in
///         the vault and every request is alone in its bucket, so every figure is exact: no pro-rata slice, no
///         rounding dust. Whatever precondition is not met (a membership that lapsed, a fill the hub refuses, an
///         escrow reserved past its balance) leaves the cycle unchecked rather than failed.
abstract contract MultiRequestTargets is ConservationTargets {
    uint256 internal constant MAX_REQUESTS = 5;

    /// @dev What a multi-request cycle keeps, in memory to stay clear of the stack limit.
    struct Multi {
        ConservedCycle c;
        uint256 seed;
        uint256 count;
        bool moves;
        uint256[MAX_REQUESTS] requestIds;
        uint128[MAX_REQUESTS] sent;
        /// @dev What the hub settled of each request so far, filled and cancelled, in the request's unit.
        uint128[MAX_REQUESTS] settled;
        /// @dev How each request is settled: 0 in full, 1 a part then the rest, 2 a part then a cancellation of the
        ///      rest, 3 cancelled whole.
        uint8[MAX_REQUESTS] modes;
        uint128[MAX_REQUESTS] firstFill;
    }

    /// @dev The per-request vault and the two per-period ones, one with a horizon past the controller's own slots.
    function _multiVault(uint256 seed) internal pure returns (uint8) {
        uint8[3] memory choices = [0, 1, 4];
        return choices[seed % 3];
    }

    /// @dev Constant prices: each fill is checked at the price it was made at, and the prices the cycle starts with are
    ///      the ones every request settles at.
    function flow_manyRequests(
        uint256 actorSeed,
        uint256 vaultSeed,
        uint256 amountSeed,
        uint256 fillSeed,
        uint8 requests,
        bool isDeposit
    ) public updateGhosts(OpType.MANAGER) {
        if (_manyRequests(actorSeed, vaultSeed, amountSeed, fillSeed, requests, isDeposit, false)) {
            _ok("flow_manyRequests");
        }
    }

    /// @dev The share price moves before every fill, so each request settles at a price of its own and a claim pays
    ///      what each fill settled at, whatever the price is by then. Not under `updateGhosts`: the price move is a
    ///      `PRICE` operation, and the deltas checked after a `MANAGER` one hold it to no price change.
    function flow_manyRequestsAcrossPrice(
        uint256 actorSeed,
        uint256 vaultSeed,
        uint256 amountSeed,
        uint256 fillSeed,
        uint8 requests,
        bool isDeposit
    ) public {
        if (_manyRequests(actorSeed, vaultSeed, amountSeed, fillSeed, requests, isDeposit, true)) {
            _ok("flow_manyRequestsAcrossPrice");
        }
    }

    /// @dev Three or four requests of one controller, each in a window of its own inside the horizon, all settled and
    ///      none folded by a keeper: the views must already count every one, and the claim alone must take them all in,
    ///      so a position the horizon failed to keep would stay open here. A per-period vault only, since the
    ///      per-request vault folds when it settles.
    function flow_claimFoldsTheHorizon(
        uint256 actorSeed,
        uint256 vaultSeed,
        uint256 amountSeed,
        uint256 fillSeed,
        uint8 requests,
        bool isDeposit
    ) public updateGhosts(OpType.MANAGER) {
        Multi memory m;
        actorSeed %= 2 ** 128;
        m.seed = fillSeed;
        m.count = 3 + requests % 2;
        m.c.isDeposit = isDeposit;
        // `_multiVault` picks the second or third choice: the two per-period vaults
        if (!_multiOpen(m, actorSeed, 1 + vaultSeed % 2, amountSeed)) return;
        if (!_multiSettle(m)) return;
        _multiCheckClaimable(m);
        if (!_multiClaim(m)) return;
        for (uint256 i; i < m.count; i++) {
            eq(
                m.c.vault.contribution(uint96(m.requestIds[i]), m.c.actor).amount,
                0,
                "the claim left a settled position open"
            );
        }
        _conservedFinish(m.c);
        _ok("flow_claimFoldsTheHorizon");
    }

    function _manyRequests(
        uint256 actorSeed,
        uint256 vaultSeed,
        uint256 amountSeed,
        uint256 fillSeed,
        uint8 requests,
        bool isDeposit,
        bool moves
    ) internal returns (bool) {
        Multi memory m;
        // The actor helpers add to the seed, so a seed at the top of the range is kept clear of the overflow
        actorSeed %= 2 ** 128;
        m.seed = fillSeed;
        m.moves = moves;
        m.count = 2 + requests % (MAX_REQUESTS - 1);
        m.c.isDeposit = isDeposit;
        if (!_multiOpen(m, actorSeed, vaultSeed, amountSeed)) return false;
        if (!_multiSettle(m)) return false;
        if (!_multiFold(m)) return false;
        _multiCheckClaimable(m);
        if (!_multiClaim(m)) return false;
        _conservedFinish(m.c);
        t(
            m.c.vault.pendingDepositRequest(0, m.c.actor) == 0 && m.c.vault.pendingRedeemRequest(0, m.c.actor) == 0,
            "a multi-request cycle left a request pending"
        );
        return true;
    }

    //----------------------------------------------------------------------------------------------
    // Requests
    //----------------------------------------------------------------------------------------------

    /// @dev Picks the controller, which starts clean, and makes the requests, each in a bucket of its own and flushed.
    ///      The pending views then hold exactly what was requested.
    function _multiOpen(Multi memory m, uint256 actorSeed, uint256 vaultSeed, uint256 amountSeed)
        internal
        returns (bool)
    {
        ConservedCycle memory c = m.c;
        c.v = _multiVault(vaultSeed);
        c.vault = vaults[c.v];
        c.actor = c.isDeposit ? _unfrozen(actorSeed) : _liquidHolder(actorSeed);
        if (frozen[c.actor] || !_healthy(c.vault, c.actor) || _overReserved() || _hasPositionIn(c.vault, c.actor)) {
            return false;
        }
        if (!_pricesLive() || (c.isDeposit && !_fillBuysShares(_dust(true)))) return false;
        c.hasRoute = address(c.vault.liquidityRoute()) != address(0);
        _conservedStart(c);

        for (uint256 i; i < m.count; i++) {
            if (!_multiRequest(m, i, amountSeed)) return false;
        }
        uint256 pending =
            c.isDeposit ? c.vault.pendingDepositRequest(0, c.actor) : c.vault.pendingRedeemRequest(0, c.actor);
        eq(pending, c.requested, "the pending view is not what the requests hold");
        return true;
    }

    /// @dev One request, alone in its bucket and flushed. A per-period window is closed by moving to the next one, so
    ///      the request opens a window nobody else is in.
    function _multiRequest(Multi memory m, uint256 i, uint256 amountSeed) internal returns (bool) {
        ConservedCycle memory c = m.c;
        if (c.v != 0) vm.warp((block.timestamp / PERIOD + 1) * PERIOD);
        if (frozen[c.actor] || !_healthy(c.vault, c.actor)) return false;
        uint256 balance = c.isDeposit ? usdc.balanceOf(c.actor) : shareA.balanceOf(c.actor);
        uint128 dust = _dust(c.isDeposit);
        if (balance < dust) return false;
        // An even share of what is left at most, so the later requests have something to spend
        uint256 cap = balance / (m.count - i);
        uint256 amount = between(uint256(keccak256(abi.encode(amountSeed, i))), dust, cap < dust ? dust : cap);
        (bool requested, uint256 requestId) =
            c.isDeposit ? _requestDeposit(c.actor, c.actor, c.v, amount) : _requestRedeem(c.actor, c.actor, c.v, amount);
        if (!requested) return false;

        uint96 localId = uint96(requestId);
        if (c.vault.bucket(localId).total != amount || c.vault.contribution(localId, c.actor).amount != amount) {
            return false;
        }
        Req memory r = Req(c.v, requestId, c.isDeposit);
        if (!_flushQueued(r) || _outstanding(r) != amount) return false;
        m.requestIds[i] = requestId;
        m.sent[i] = uint128(amount);
        c.requested += amount;
        return true;
    }

    //----------------------------------------------------------------------------------------------
    // Settlement
    //----------------------------------------------------------------------------------------------

    /// @dev Two rounds in an order other than the one the requests were made in: the first fills a request, fills a
    ///      part of it or cancels it, and the pending views must then have dropped by what settled; the second finishes
    ///      the parts, filling the rest or cancelling it. Every request ends settled.
    function _multiSettle(Multi memory m) internal returns (bool) {
        uint128 dust = _dust(m.c.isDeposit);
        for (uint256 i; i < m.count; i++) {
            uint256 w = uint256(keccak256(abi.encode(m.seed, i)));
            uint128 sent = m.sent[i];
            uint8 mode = uint8(w % 4);
            bool canSplit = sent >= 2 * dust;
            if ((mode == 1 || mode == 2) && !canSplit) mode = 0;
            m.modes[i] = mode;
            if (mode == 1 || mode == 2) m.firstFill[i] = uint128(between(w / 4, dust, sent - dust));
        }

        uint256 start = m.seed / 3 % m.count;
        bool reversed = m.seed / 5 % 2 == 1;
        for (uint256 j; j < m.count; j++) {
            if (!_multiFirstRound(m, _multiIndex(m, start, reversed, j))) return false;
        }
        _multiCheckPending(m);
        for (uint256 j; j < m.count; j++) {
            if (!_multiSecondRound(m, _multiIndex(m, start + 1, !reversed, j))) return false;
        }
        return true;
    }

    function _multiIndex(Multi memory m, uint256 start, bool reversed, uint256 j) internal pure returns (uint256) {
        return reversed ? (start + m.count - j % m.count) % m.count : (start + j) % m.count;
    }

    function _multiFirstRound(Multi memory m, uint256 i) internal returns (bool) {
        Req memory r = Req(m.c.v, m.requestIds[i], m.c.isDeposit);
        uint8 mode = m.modes[i];
        if (mode == 3) return _multiCancel(m, i, r, m.sent[i]);
        return _multiFill(m, i, r, mode == 0 ? m.sent[i] : m.firstFill[i]);
    }

    function _multiSecondRound(Multi memory m, uint256 i) internal returns (bool) {
        Req memory r = Req(m.c.v, m.requestIds[i], m.c.isDeposit);
        uint8 mode = m.modes[i];
        uint128 rest = m.sent[i] - m.firstFill[i];
        if (mode == 1) return _multiFill(m, i, r, rest);
        if (mode == 2) return _multiCancel(m, i, r, rest);
        return true;
    }

    /// @dev A fill at the price of the moment, which moves before it when the cycle moves prices. What it buys is read
    ///      at that price, right after, before anything moves it.
    function _multiFill(Multi memory m, uint256 i, Req memory r, uint128 fill) internal returns (bool) {
        if (m.moves) {
            uint256 w = uint256(keccak256(abi.encode(m.seed, i, fill)));
            _pushPrices(poolA, scA, d18(uint128(between(w, 5e17, 4e18))));
        }
        if (!_pricesLive() || !_fulfill(r, fill)) return false;
        m.c.filled += fill;
        m.c.output += _fillOutput(m.c.isDeposit, fill);
        m.settled[i] += fill;
        return true;
    }

    function _multiCancel(Multi memory m, uint256 i, Req memory r, uint128 gross) internal returns (bool) {
        if (!_cancel(r, gross)) return false;
        m.c.cancelled += gross;
        m.settled[i] += gross;
        return true;
    }

    /// @dev The pending views drop by what settled. A position the controller's horizon holds, or one the vault folds
    ///      when it settles (the per-request vault), is reduced by its fills and cancellations; one the horizon pushed
    ///      out unsettled, which only a keeper folds, still counts as pending in full until it is folded.
    function _multiCheckPending(Multi memory m) internal {
        IAsyncVault vault = m.c.vault;
        uint256 horizon = vault.foldHorizon();
        uint256 evicted = m.c.v == 0 || m.count <= horizon ? 0 : m.count - horizon;
        uint256 expected;
        for (uint256 i; i < m.count; i++) {
            expected += i < evicted ? m.sent[i] : m.sent[i] - m.settled[i];
        }
        uint256 pending =
            m.c.isDeposit ? vault.pendingDepositRequest(0, m.c.actor) : vault.pendingRedeemRequest(0, m.c.actor);
        eq(pending, expected, "the pending view did not drop by what settled");
    }

    //----------------------------------------------------------------------------------------------
    // Folds and claims
    //----------------------------------------------------------------------------------------------

    /// @dev Positions the horizon pushed out wait for a keeper, so those are folded; the others, in the order the
    ///      seed picks, are folded by a keeper or left for the claim to fold.
    function _multiFold(Multi memory m) internal returns (bool) {
        IAsyncVault vault = m.c.vault;
        uint256 horizon = vault.foldHorizon();
        uint256 evicted = m.c.v == 0 || m.count <= horizon ? 0 : m.count - horizon;
        for (uint256 j; j < m.count; j++) {
            uint256 i = _multiIndex(m, m.seed / 7, m.seed / 11 % 2 == 1, j);
            bool keeper = i < evicted || (m.seed >> (13 + i)) % 2 == 1;
            if (!keeper || vault.contribution(uint96(m.requestIds[i]), m.c.actor).amount == 0) continue;
            _foldOne(m.c.v, uint96(m.requestIds[i]), m.c.actor);
        }
        return !frozen[m.c.actor] && _healthy(vault, m.c.actor);
    }

    /// @dev What the controller can claim is what the fills settled, at the prices they settled at: the filled shares
    ///      and assets, and the refund of what was cancelled, on the side that refund comes back on. Whichever of
    ///      these positions were folded, the views count the ones in the horizon. And the aggregate request views are
    ///      what the `max*` views report, for a controller the hook does not refuse.
    function _multiCheckClaimable(Multi memory m) internal {
        IAsyncVault vault = m.c.vault;
        address actor = m.c.actor;
        ConservedCycle memory c = m.c;
        // Deposit requests: filled shares and their assets on the deposit side, the refunded assets on the redeem side.
        // Redeem requests: filled assets and their shares on the redeem side, the refunded shares on the deposit side.
        eq(vault.claimableMint(actor), c.isDeposit ? c.output : c.cancelled, "the claimable shares are not the fills'");
        eq(
            vault.claimableDepositRequest(0, actor),
            c.isDeposit ? c.filled : 0,
            "the claimable deposit request is not what the fills took"
        );
        eq(
            vault.claimableWithdraw(actor),
            c.isDeposit ? c.cancelled : c.output,
            "the claimable assets are not the fills'"
        );
        eq(
            vault.claimableRedeemRequest(0, actor),
            c.isDeposit ? 0 : c.filled,
            "the claimable redeem request is not what the fills took"
        );
        if (frozen[actor] || !_healthy(vault, actor)) return;
        if (vault.claimableDepositRequest(0, actor) != 0) {
            eq(
                vault.maxDeposit(actor),
                vault.claimableDepositRequest(0, actor),
                "maxDeposit != claimableDepositRequest"
            );
        }
        if (vault.claimableRedeemRequest(0, actor) != 0) {
            eq(vault.maxRedeem(actor), vault.claimableRedeemRequest(0, actor), "maxRedeem != claimableRedeemRequest");
        }
    }

    /// @dev Claims in two to four parts, each through any of the four entrypoints, by the controller or its operator, in
    ///      an amount anywhere up to the most the side takes in that unit, then everything that is left. Every part
    ///      is checked as the single-claim handlers check one (the ledger shrinks by what it paid, the escrow gives up
    ///      what the controller gets); the last claim, of the whole of each side, must go through.
    function _multiClaim(Multi memory m) internal returns (bool) {
        ConservedCycle memory c = m.c;
        uint256 parts = 2 + m.seed / 17 % 3;
        for (uint256 p; p < parts; p++) {
            // A part may run past a membership that lapsed or the share hook's view of the controller
            if (frozen[c.actor] || !_healthy(c.vault, c.actor)) return false;
            uint256 w = uint256(keccak256(abi.encode(m.seed, "claim", p)));
            bool isDeposit = w % 2 == 0;
            bool byShares = w / 2 % 2 == 1;
            uint256 max = _claimMax(c.vault, c.actor, isDeposit, byShares);
            if (max == 0) continue;
            uint256 amount = between(w / 16, 1, max);
            if (w / 4 % 3 == 0) {
                _claimThroughOperator(c.vault, c.actor, _actor(w / 64), isDeposit, byShares, amount);
            } else if (isDeposit) {
                _claimDeposit(c.vault, c.actor, amount, byShares, false);
            } else {
                _claimRedeem(c.vault, c.actor, amount, byShares, false);
            }
        }
        if (frozen[c.actor] || !_healthy(c.vault, c.actor)) return false;
        _claimAll(c.vault, c.actor, 1);
        return !_overReserved();
    }

    /// @dev An operator claims for the controller, with the controller as receiver: what the controller receives is
    ///      what the ledger gave up, in both units, and nobody else's balance is part of it.
    function _claimThroughOperator(
        IAsyncVault vault,
        address actor,
        address operator,
        bool isDeposit,
        bool byShares,
        uint256 amount
    ) internal {
        if (operator == actor) return;
        uint256[4] memory before = [shareA.balanceOf(actor), usdc.balanceOf(actor), 0, 0];
        uint256[2] memory ledger = _ledger(vault, actor, isDeposit);
        uint8 k = (isDeposit ? 0 : 2) + (byShares ? 1 : 0);
        (bool success, uint256 returned) = _operatorCall(vault, actor, operator, k, amount);
        if (!success) return _reverted("flow_manyRequests_operator");

        // What was paid in both units: the amount the claim was made in, and what it returned in the other
        uint256 shares = k % 2 == 1 ? amount : returned;
        uint256 assets = k % 2 == 1 ? returned : amount;
        eq(shareA.balanceOf(actor), before[0] + (isDeposit ? shares : 0), "an operator's claim paid other shares");
        eq(usdc.balanceOf(actor), before[1] + (isDeposit ? 0 : assets), "an operator's claim paid other assets");
        _ledgerMoved(vault, actor, ledger, isDeposit, shares, assets);
        _countClaimed(address(vault), actor, before[0], before[1]);
        t(!frozen[actor], "an operator claimed for a frozen controller");
        _ok("flow_manyRequests_operator");
    }

    /// @dev The operator's call, the controller having made it an operator for the call only.
    function _operatorCall(IAsyncVault vault, address actor, address operator, uint8 k, uint256 amount)
        internal
        returns (bool success, uint256 returned)
    {
        bool wasOperator = vault.isOperator(actor, operator);
        vm.prank(actor);
        vault.setOperator(operator, true);
        bytes memory ret;
        (success, ret) = _boundedCall(
            operator,
            address(vault),
            _multiClaimCall(k, amount, actor),
            "an operator's claim cost more gas than the ceiling"
        );
        vm.prank(actor);
        vault.setOperator(operator, wasOperator);
        if (success) returned = abi.decode(ret, (uint256));
    }

    /// @dev One of the four 3-argument claims for `controller` paid to it: deposit, mint, withdraw or redeem.
    function _multiClaimCall(uint8 k, uint256 amount, address controller) internal pure returns (bytes memory) {
        string memory sig = k == 0
            ? "deposit(uint256,address,address)"
            : k == 1
                ? "mint(uint256,address,address)"
                : k == 2 ? "withdraw(uint256,address,address)" : "redeem(uint256,address,address)";
        return abi.encodeWithSignature(sig, amount, controller, controller);
    }

    /// @dev Whether the hub's prices are both set: a fill at a zero one converts to nothing and the OrderBook refuses it.
    function _pricesLive() internal view returns (bool) {
        D18 ppa = hub.pricePoolPerAsset(poolA, scA, usdcId);
        (D18 pps,) = shareClassManager.pricePoolPerShare(poolA, scA);
        return !ppa.isZero() && !pps.isZero();
    }
}
