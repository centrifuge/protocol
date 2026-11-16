// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {FoldResult, BucketReference} from "./BucketReference.sol";

import {BucketLib} from "../../src/vaults/libraries/BucketLib.sol";
import {HorizonLib} from "../../src/vaults/libraries/HorizonLib.sol";
import {
    Bucket,
    Contribution,
    IVaultErrors,
    InvestmentState,
    UnfoldedState
} from "../../src/vaults/interfaces/IAsyncVault.sol";

import "forge-std/Test.sol";

/// @dev Drives `BucketLib` through arbitrary interleavings of the operations a vault performs on it,
///      including the auto-fold horizon the vault keeps beside it (evicting the oldest past the horizon,
///      dropped on transfer and on a completing claim fold; a contribution the handler leaves untracked
///      stands for a position outside it), the pending
///      totals, and the vault's id allocation: a
///      request either takes the next fresh id, joins a live bucket (a batching window, or a sole
///      owner topping up), or names an older id, which is a retired one being reused or a dead one
///      being rejected.
///
///      Every state change runs inside a self-call (`do*`, never a fuzz target) so that a rejected
///      operation rolls back the library state, the cursor and the ghosts together, the way a reverted
///      vault transaction would. The fuzz targets themselves never revert: they count what succeeded
///      and what the library rejected, so a run's statistics say which paths were actually exercised.
///
///      `fold` is the exception to "rejections are fine": the vault folds on every claim, so a fold
///      that reverts freezes a position. It is wrapped and recorded, and an invariant asserts it never
///      happened.
///
///      The properties are evaluated here, over storage, and only over live buckets: they run after
///      every call, and reading every bucket through getters from the test contract costs thousands of
///      external calls per check. A bucket that dies (spent, every stake folded out, never to change
///      again) is checked one last time as it leaves the live set, and a violation then is recorded.
contract BucketHandler is Test {
    using BucketLib for BucketLib.State;
    using HorizonLib for HorizonLib.State;
    using BucketReference for BucketLib.State;

    /// @dev Small, so eviction is reached often
    uint256 public constant HORIZON = 3;
    /// @dev Per-bucket ceiling for the denominator and each settled leg. A controller's pending total
    ///      sums every bucket it holds into a uint128, so this keeps every reachable state inside what
    ///      the views can represent; inside it amounts range over the full magnitude spectrum down to
    ///      1 wei.
    uint128 public immutable CAP;

    BucketLib.State internal s;
    HorizonLib.State internal h;
    mapping(address => InvestmentState) internal _ledgers;
    address[] public actors;

    /// @dev The highest id handed out, as the vault's `_localNonce`
    uint96 public nonce;
    uint96[] public live;
    mapping(uint96 => uint256) internal _liveIndex;

    // Ghosts per bucket, for the current epoch (a retirement starts a new one)
    mapping(uint96 => uint256) public epoch;
    mapping(uint96 => uint128) public ghostMaxTotal;
    mapping(uint96 => uint32) public ghostMaxSettlements;
    mapping(uint96 => bool) public ghostShared;
    mapping(uint96 => uint256) public ghostParts;
    mapping(uint96 => mapping(address => uint256)) internal _partEpoch;
    mapping(uint96 => uint256[4]) internal _ghostFolded;

    // Reachability and recorded failures
    bool public foldReverted;
    /// @dev The first action that reverted for a reason the library does not give, with that reason.
    string public unexpectedRevert;
    string public deadViolation;
    /// @dev What a fold credited against what it reported, and what the views promised against what a fold then
    ///      credited: the first violation of either, or empty.
    string public creditViolation;
    uint256 public retirements;
    uint256 public reuses;
    uint256 public spentBuckets;
    uint256 public deadBuckets;
    uint256 public transfers;
    /// @dev Transfers that went through with the sender's fold not current, so its settled slice moved too.
    uint256 public staleTransfers;
    /// @dev Transfers refused because the sender's fold was deferred, which shows the case is reached.
    uint256 public deferredTransfers;
    uint256 public evictions;
    uint256 public untracked;
    uint256 public sharedSettlements;
    mapping(bytes4 => uint256) public succeeded;
    mapping(bytes4 => uint256) public rejected;

    constructor(uint256 nActors, uint128 cap) {
        CAP = cap;
        for (uint256 i; i < nActors; i++) {
            actors.push(address(uint160(0xA000 + i)));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function liveCount() external view returns (uint256) {
        return live.length;
    }

    function ghostFolded(uint96 lid) external view returns (uint256[4] memory) {
        return _ghostFolded[lid];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev An id for a new request: fresh three times in eight, any id handed out so far one time in
    ///      eight, otherwise a live bucket.
    function _requestId(uint256 seed) internal view returns (uint96) {
        uint256 mode = seed % 8;
        if (mode < 3 || nonce == 0) return nonce + 1;
        if (mode == 3 || live.length == 0) return uint96(_bound(seed >> 3, 1, nonce));
        return live[(seed >> 3) % live.length];
    }

    /// @dev A live bucket to act on, or zero if there is none
    function _liveId(uint256 seed) internal view returns (uint96) {
        return live.length == 0 ? 0 : live[seed % live.length];
    }

    /// @dev The first live bucket from `seed` on with something queued (`queued`) or sent and still
    ///      pending (`!queued`), or zero. Aiming keepers and the request manager at buckets they can act
    ///      on keeps the run from spending its depth on calls that cannot succeed.
    function _actionable(uint256 seed, bool queued) internal view returns (uint96) {
        for (uint256 i; i < live.length; i++) {
            uint96 lid = live[(seed % live.length + i) % live.length];
            Bucket storage b = s.buckets[lid];
            if (queued ? b.queued != 0 : s.outstanding(lid) > b.queued) return lid;
        }
        return 0;
    }

    /// @dev The first actor from `seed` on that holds a stake in `lid`, or zero
    function _staker(uint96 lid, uint256 seed) internal view returns (address) {
        for (uint256 i; i < actors.length; i++) {
            address who = actors[(seed % actors.length + i) % actors.length];
            if (s.contributions[lid][who].amount != 0) return who;
        }
        return address(0);
    }

    /// @dev An amount in `[1, max]` drawn log-uniformly (the low byte picks the magnitude), so 1 wei,
    ///      1e6, 1e18 and 1e36 are all common.
    function _amount(uint256 seed, uint256 max) internal pure returns (uint128) {
        if (max == 0) return 0;
        uint256 ceiling = 10 ** ((seed & 0xff) % 39);
        return uint128(_bound(seed >> 8, 1, ceiling < max ? ceiling : max));
    }

    function _record(bool ok) internal {
        if (ok) succeeded[msg.sig]++;
        else rejected[msg.sig]++;
    }

    /// @dev A rejection must be one the library means: one of its typed errors. A panic, an empty revert or any
    ///      other reason is recorded as a violation, since a swallowed revert would hide an action that broke.
    function _reject(bytes memory reason) internal {
        _record(false);
        if (reason.length >= 4 && _isLibraryError(bytes4(reason))) return;
        if (bytes(unexpectedRevert).length == 0) {
            unexpectedRevert = string.concat(
                "unexpected revert in ", vm.toString(abi.encodePacked(msg.sig)), ": ", vm.toString(reason)
            );
        }
    }

    function _isLibraryError(bytes4 selector) internal pure returns (bool) {
        return selector == IVaultErrors.BucketNotFlushed.selector || selector == IVaultErrors.BucketSealed.selector
            || selector == IVaultErrors.FoldDeferred.selector || selector == IVaultErrors.InvalidController.selector
            || selector == IVaultErrors.NoContribution.selector || selector == IVaultErrors.NoPendingRequest.selector
            || selector == IVaultErrors.NoQueuedRequest.selector || selector == IVaultErrors.OneSidedFill.selector
            || selector == IVaultErrors.OverSettled.selector || selector == IVaultErrors.RequestIdInUse.selector;
    }

    modifier onlySelf() {
        require(msg.sender == address(this), "handler only");
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Actions
    //----------------------------------------------------------------------------------------------

    /// @dev Side follows the bucket's when it has one, except one time in sixteen, which keeps the
    ///      side-mismatch rejection exercised without letting it eat the run. Half the requests are
    ///      sent at once, as a per-request or per-investor policy does; the rest wait in the queue for
    ///      a `flush`, as a batching window does.
    function contribute(uint256 actorSeed, uint256 lidSeed, uint256 sideSeed, uint256 amountSeed) external {
        uint96 lid = _requestId(lidSeed);
        Bucket memory b = s.buckets[lid];
        bool isDeposit = (b.total == 0 || sideSeed % 16 == 0) ? sideSeed % 2 == 0 : b.isDeposit;
        uint128 amount = _amount(amountSeed, CAP - b.total);
        if (amount == 0) return;

        bool tracked = (sideSeed >> 5) % 4 != 0;
        try this.doContribute(lid, _actor(actorSeed), isDeposit, amount, (sideSeed >> 4) % 2 == 0, tracked) {
            _record(true);
        } catch (bytes memory reason) {
            _reject(reason);
        }
    }

    /// @dev Many own requests in a row from one controller, each to a fresh id, so the horizon fills
    ///      and evicts in a reachable number of steps. Stops at the first rejection.
    function contributeMany(uint256 actorSeed, uint8 count, uint256 amountSeed) external {
        address who = _actor(actorSeed);
        uint256 n = _bound(count, 1, 3 * HORIZON);
        for (uint256 i; i < n; i++) {
            uint128 amount = _amount(uint256(keccak256(abi.encode(amountSeed, i))), CAP);
            try this.doContribute(nonce + 1, who, (amountSeed >> i) % 2 == 0, amount, true, true) {
                _record(true);
            } catch (bytes memory reason) {
                _reject(reason);
                break;
            }
        }
    }

    function flush(uint256 lidSeed) external {
        uint96 lid = _actionable(lidSeed, true);
        if (lid == 0) return;

        try this.doFlush(lid) {
            _record(true);
        } catch (bytes memory reason) {
            _reject(reason);
        }
    }

    /// @dev A partial fulfillment: the native leg bounded by what was sent and is still pending, the
    ///      other leg anywhere in range.
    function settle(uint256 lidSeed, uint256 legSeed, uint256 otherSeed) external {
        uint96 lid = _actionable(lidSeed, false);
        Bucket memory b = s.buckets[lid];
        uint128 sendable = s.outstanding(lid) - b.queued;
        if (sendable == 0) return;

        uint128 leg = _amount(legSeed, sendable);
        uint128 other = _amount(otherSeed, CAP - (b.isDeposit ? b.fulfilledShares : b.fulfilledAssets));
        if (other == 0) return;
        (uint128 assets, uint128 shares) = b.isDeposit ? (leg, other) : (other, leg);

        try this.doSettle(lid, b.isDeposit, assets, shares, 0, 0) {
            _record(true);
        } catch (bytes memory reason) {
            _reject(reason);
        }
    }

    /// @dev Settles everything that was sent, split between a fill and a cancellation with a fee (or a
    ///      rebate). Without it a uniformly drawn partial settlement almost never spends a bucket, and
    ///      the retirement, completion and dust properties are never reached.
    function settleRest(uint256 lidSeed, uint256 cancelSeed, uint256 otherSeed, uint256 netSeed) external {
        uint96 lid = _actionable(lidSeed, false);
        Bucket memory b = s.buckets[lid];
        uint128 rest = s.outstanding(lid) - b.queued;
        if (rest == 0) return;

        uint128 gross = cancelSeed % 3 == 0 ? 0 : (cancelSeed % 3 == 1 ? rest : uint128(_bound(cancelSeed, 0, rest)));
        uint128 fill = rest - gross;
        uint128 other = fill == 0 ? 0 : _amount(otherSeed, CAP - (b.isDeposit ? b.fulfilledShares : b.fulfilledAssets));
        if (fill != 0 && other == 0) return;
        uint128 net = _net(gross, netSeed, CAP - b.cancelledNet);
        (uint128 assets, uint128 shares) = b.isDeposit ? (fill, other) : (other, fill);

        try this.doSettle(lid, b.isDeposit, assets, shares, gross, net) {
            _record(true);
        } catch (bytes memory reason) {
            _reject(reason);
        }
    }

    function cancel(uint256 lidSeed, uint256 grossSeed, uint256 netSeed) external {
        uint96 lid = _actionable(lidSeed, false);
        Bucket memory b = s.buckets[lid];
        uint128 sendable = s.outstanding(lid) - b.queued;
        if (sendable == 0) return;

        uint128 gross = _amount(grossSeed, sendable);
        uint128 net = _net(gross, netSeed, CAP - b.cancelledNet);

        try this.doSettle(lid, b.isDeposit, 0, 0, gross, net) {
            _record(true);
        } catch (bytes memory reason) {
            _reject(reason);
        }
    }

    /// @dev Net is usually below gross (a retained fee), sometimes equal, sometimes above (a rebate).
    function _net(uint128 gross, uint256 seed, uint128 room) internal pure returns (uint128 net) {
        uint256 mode = seed % 4;
        if (mode == 0) net = gross;
        else if (mode == 3) net = uint128(_bound(seed >> 2, gross, uint256(gross) + gross / 2));
        else net = uint128(_bound(seed >> 2, 0, gross));
        if (net > room) net = room;
    }

    /// @dev `foldRequest`: one bucket, leaving the horizon as it is.
    function fold(uint256 actorSeed, uint256 lidSeed) external {
        uint96 lid = _liveId(lidSeed);
        address who = _staker(lid, actorSeed);
        if (who == address(0)) return;

        try this.doFold(lid, who) {
            _record(true);
        } catch {
            foldReverted = true;
        }
    }

    /// @dev `HorizonLib.fold`: the claim path, folding the horizon.
    function foldRecent(uint256 actorSeed) external {
        try this.doFoldRecent(_actor(actorSeed)) {
            _record(true);
        } catch {
            foldReverted = true;
        }
    }

    /// @dev `transferRequest`: fold the sender, move what is left, drop it from the sender's horizon and,
    ///      when it is tracked, add it to theirs.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 lidSeed) external {
        uint96 lid = _liveId(lidSeed);
        address from = _staker(lid, fromSeed);
        address to = _actor(toSeed);
        if (from == address(0) || from == to) return;

        try this.doTransfer(lid, from, to, (toSeed >> 8) % 2 == 0) {
            _record(true);
        } catch (bytes memory reason) {
            if (bytes4(reason) == IVaultErrors.FoldDeferred.selector) deferredTransfers++;
            _reject(reason);
        }
    }

    /// @dev Moves one of a controller's ledger counters to within a bucket's size of the top of its range, so the
    ///      credits that follow meet the limit. The harness otherwise keeps every amount a controller could hold
    ///      inside what a `uint128` can sum, which is why nothing here could overflow before this action.
    function primeLedger(uint256 actorSeed, uint256 fieldSeed, uint256 headroomSeed) external {
        _setField(_ledgers[_actor(actorSeed)], fieldSeed, type(uint128).max - _amount(headroomSeed, CAP));
        _record(true);
    }

    /// @dev A claim: takes a share of one counter out of the ledger, as claiming does, which is what makes room for
    ///      a deferred fold.
    function claimLedger(uint256 actorSeed, uint256 fieldSeed, uint256 shareSeed) external {
        InvestmentState storage l = _ledgers[_actor(actorSeed)];
        uint128 now_ = _getField(l, fieldSeed);
        _setField(
            l,
            fieldSeed,
            uint128(uint256(now_) * (shareSeed % 101) / 100) == 0
                ? 0
                : now_ - uint128(uint256(now_) * (shareSeed % 101) / 100)
        );
        _record(true);
    }

    function _getField(InvestmentState storage l, uint256 field) internal view returns (uint128) {
        uint256 f = field % 6;
        if (f == 0) return l.depositShares;
        if (f == 1) return l.depositAssets;
        if (f == 2) return l.redeemAssets;
        if (f == 3) return l.redeemShares;
        if (f == 4) return l.refundShares;
        return l.refundAssets;
    }

    function _setField(InvestmentState storage l, uint256 field, uint128 value) internal {
        uint256 f = field % 6;
        if (f == 0) l.depositShares = value;
        else if (f == 1) l.depositAssets = value;
        else if (f == 2) l.redeemAssets = value;
        else if (f == 3) l.redeemShares = value;
        else if (f == 4) l.refundShares = value;
        else l.refundAssets = value;
    }

    //----------------------------------------------------------------------------------------------
    // Atomic bodies (self-call only, excluded from the fuzz targets)
    //----------------------------------------------------------------------------------------------

    function doContribute(uint96 lid, address who, bool isDeposit, uint128 amount, bool flushNow, bool tracked)
        external
        onlySelf
    {
        bool reused = s.buckets[lid].total == 0 && epoch[lid] != 0;
        s.contribute(lid, who, isDeposit, amount, true, 0);
        if (tracked) _remember(who, lid, isDeposit);
        else untracked++;
        if (flushNow) s.flush(lid);
        if (reused) reuses++;
        if (lid > nonce) nonce = lid;
        _notePart(lid, who);

        uint128 total = s.buckets[lid].total;
        if (total > ghostMaxTotal[lid]) ghostMaxTotal[lid] = total;
        _sync(lid);
    }

    function doFlush(uint96 lid) external onlySelf {
        s.flush(lid);
    }

    function doSettle(uint96 lid, bool isDeposit, uint128 assets, uint128 shares, uint128 gross, uint128 net)
        external
        onlySelf
    {
        s.settle(lid, isDeposit, assets, shares, gross, net);
        ghostMaxSettlements[lid] = s.buckets[lid].settlements;
        if (s.outstanding(lid) == 0) spentBuckets++;
        if (ghostShared[lid]) sharedSettlements++;
    }

    function doFold(uint96 lid, address who) external onlySelf {
        _fold(lid, who);
        _sync(lid);
    }

    /// @dev Mirrors `HorizonLib.fold` through `_fold`, so the ghosts see every slice.
    function doFoldRecent(address who) external onlySelf {
        UnfoldedState memory promised = h.unfolded(s, _ledgers[who], who);
        InvestmentState memory before = _ledgers[who];
        for (uint256 side; side < 2; side++) {
            bool isDeposit = side == 0;
            uint96[] memory ids = h.entries(s, who, isDeposit);
            for (uint256 i; i < ids.length; i++) {
                // An entry whose id was reused on the other side is stale: a claim drops it unfolded
                if (s.buckets[ids[i]].isDeposit != isDeposit) {
                    h.remove(s, who, ids[i], isDeposit);
                    continue;
                }
                if (_fold(ids[i], who)) h.remove(s, who, ids[i], isDeposit);
                _sync(ids[i]);
            }
        }
        _checkPromise(who, promised, before);
    }

    /// @dev The views of a controller's claimable balances promise what folding its horizon then credits: the
    ///      two defer the same positions, so a view never offers what a claim could not take.
    function _checkPromise(address who, UnfoldedState memory promised, InvestmentState memory before) internal {
        InvestmentState storage l = _ledgers[who];
        string memory field;
        if (l.depositShares - before.depositShares != promised.depositShares) field = "maxMint";
        else if (l.depositAssets - before.depositAssets != promised.depositAssets) field = "depositAssets";
        else if (l.redeemAssets - before.redeemAssets != promised.redeemAssets) field = "maxWithdraw";
        else if (l.redeemShares - before.redeemShares != promised.redeemShares) field = "redeemShares";
        else if (l.refundShares - before.refundShares != promised.refundShares) field = "refundShares";
        else if (l.refundAssets - before.refundAssets != promised.refundAssets) field = "refundAssets";
        if (bytes(field).length != 0 && bytes(creditViolation).length == 0) {
            creditViolation = string.concat("a fold credited other than the view promised, in ", field);
        }
    }

    function doTransfer(uint96 lid, address from, address to, bool tracked) external onlySelf {
        bool isDeposit = s.buckets[lid].isDeposit;
        _fold(lid, from);
        // Counted only if the transfer then goes through, since its revert unwinds this call
        if (s.contributions[lid][from].foldedSettlements != s.buckets[lid].settlements) staleTransfers++;
        s.transfer(lid, from, to);
        h.remove(s, from, lid, isDeposit);
        if (tracked) _remember(to, lid, isDeposit);
        _notePart(lid, to);
        transfers++;
        _sync(lid);
    }

    /// @dev The vault's `_addRecent`, with the eviction folded through `_fold` so the ghosts see it; the
    ///      library's own eviction is covered by the vault tests.
    function _remember(address who, uint96 lid, bool isDeposit) internal {
        if (h.contains(s, who, lid, isDeposit)) return;
        while (h.entries(s, who, isDeposit).length >= HORIZON) {
            uint96 oldest = h.entries(s, who, isDeposit)[0];
            _fold(oldest, who);
            h.remove(s, who, oldest, isDeposit);
            _sync(oldest);
            evictions++;
        }
        h.add(s, _ledgers[who], who, lid, isDeposit, true, type(uint256).max);
    }

    function _notePart(uint96 lid, address who) internal {
        if (_partEpoch[lid][who] != epoch[lid] + 1) {
            _partEpoch[lid][who] = epoch[lid] + 1;
            ghostParts[lid]++;
        }
        if (ghostParts[lid] > 1) ghostShared[lid] = true;
    }

    function _fold(uint96 lid, address who) internal returns (bool completed) {
        bool wasLive = s.buckets[lid].total != 0;
        InvestmentState memory before = _ledgers[who];
        FoldResult memory r = s.fold(_ledgers[who], lid, who);
        _checkCredit(who, before, r);
        uint256[4] storage folded = _ghostFolded[lid];
        folded[0] += r.assets;
        folded[1] += r.shares;
        folded[2] += r.cancelledGross;
        folded[3] += r.cancelledNet;
        if (wasLive && s.buckets[lid].total == 0) _retire(lid);
        return r.completed;
    }

    /// @dev A fold credits exactly the slice it reports, on the side's ledger unit gate and nowhere else, and a fold
    ///      deferred for want of room reports nothing and changes nothing.
    function _checkCredit(address who, InvestmentState memory before, FoldResult memory r) internal {
        InvestmentState storage l = _ledgers[who];
        bool credited = r.isDeposit ? r.shares != 0 : r.assets != 0;
        bool ok = r.isDeposit
            ? (l.depositShares - before.depositShares == (credited ? r.shares : 0)
                    && l.depositAssets - before.depositAssets == (credited ? r.assets : 0)
                    && l.refundAssets - before.refundAssets == r.cancelledNet && l.redeemAssets == before.redeemAssets
                    && l.redeemShares == before.redeemShares && l.refundShares == before.refundShares)
            : (l.redeemAssets - before.redeemAssets == (credited ? r.assets : 0)
                    && l.redeemShares - before.redeemShares == (credited ? r.shares : 0)
                    && l.refundShares - before.refundShares == r.cancelledNet && l.depositShares == before.depositShares
                    && l.depositAssets == before.depositAssets && l.refundAssets == before.refundAssets);
        if (!ok && bytes(creditViolation).length == 0) creditViolation = "a fold credited other than it reported";
    }

    /// @dev A sole owner folded out of a spent bucket: the id is fresh again, so its ghosts restart.
    function _retire(uint96 lid) internal {
        retirements++;
        epoch[lid]++;
        delete ghostMaxTotal[lid];
        delete ghostMaxSettlements[lid];
        delete ghostShared[lid];
        delete ghostParts[lid];
        delete _ghostFolded[lid];
    }

    /// @dev Keeps the live set current. A bucket leaves it when retired, or when it is dead: spent
    ///      with every stake folded out, so nothing can ever change it again. The dead one is checked
    ///      a last time on the way out, which is where its final dust bound is decided.
    function _sync(uint96 lid) internal {
        Bucket storage b = s.buckets[lid];
        bool dead = b.total != 0 && s.outstanding(lid) == 0 && _stakes(lid) == 0;
        bool isLive = b.total != 0 && !dead;
        uint256 index = _liveIndex[lid];

        if (isLive && index == 0) {
            live.push(lid);
            _liveIndex[lid] = live.length;
        } else if (!isLive && index != 0) {
            uint96 last = live[live.length - 1];
            live[index - 1] = last;
            _liveIndex[last] = index;
            live.pop();
            delete _liveIndex[lid];
            if (dead) {
                deadBuckets++;
                try this.checkBucket(lid) {}
                catch Error(string memory reason) {
                    if (bytes(deadViolation).length == 0) deadViolation = reason;
                }
            }
        }
    }

    function _stakes(uint96 lid) internal view returns (uint256 sum) {
        for (uint256 a; a < actors.length; a++) {
            sum += s.contributions[lid][actors[a]].amount;
        }
    }

    //----------------------------------------------------------------------------------------------
    // Properties
    //----------------------------------------------------------------------------------------------

    /// @dev Every per-bucket property, for one bucket
    function checkBucket(uint96 lid) public view {
        _checkDenominator(lid);
        _checkPending(lid);
        _checkConservation(lid);
        _checkRetirement(lid);
        _checkSettlementCount(lid);
    }

    function checkDenominator() external view {
        for (uint256 i; i < live.length; i++) {
            _checkDenominator(live[i]);
        }
    }

    function checkPending() external view {
        for (uint256 i; i < live.length; i++) {
            _checkPending(live[i]);
        }
    }

    function checkConservation() external view {
        for (uint256 i; i < live.length; i++) {
            _checkConservation(live[i]);
        }
    }

    function checkRetirement() external view {
        for (uint256 i; i < live.length; i++) {
            _checkRetirement(live[i]);
        }
    }

    function checkSettlementCount() external view {
        for (uint256 i; i < live.length; i++) {
            _checkSettlementCount(live[i]);
        }
    }

    function _checkDenominator(uint96 lid) internal view {
        uint128 total = s.buckets[lid].total;
        require(total >= ghostMaxTotal[lid], "bucket denominator shrank");
        require(_stakes(lid) <= total, "contributions exceed the denominator");
    }

    function _checkPending(uint96 lid) internal view {
        Bucket storage b = s.buckets[lid];
        require(s.outstanding(lid) >= b.queued, "less outstanding than queued");
    }

    function _checkConservation(uint96 lid) internal view {
        Bucket storage b = s.buckets[lid];
        uint256[4] memory owed = _ghostFolded[lid];
        uint256[4] memory settledSum;
        for (uint256 a; a < actors.length; a++) {
            Contribution storage c = s.contributions[lid][actors[a]];
            (uint128 sa, uint128 ss, uint128 sc, uint128 sn) = s.settled(lid, actors[a]);
            settledSum[0] += sa;
            settledSum[1] += ss;
            settledSum[2] += sc;
            settledSum[3] += sn;
            if (c.amount == 0) continue;
            require(c.foldedAssets <= sa, "folded assets ran ahead of settled");
            require(c.foldedShares <= ss, "folded shares ran ahead of settled");
            require(c.foldedCancelledGross <= sc, "folded cancellation ran ahead of settled");
            require(c.foldedCancelledNet <= sn, "folded net cancellation ran ahead of settled");
            require(s.pendingNow(lid, actors[a]) <= c.amount, "pending exceeds what was contributed");
            owed[0] += sa - c.foldedAssets;
            owed[1] += ss - c.foldedShares;
            owed[2] += sc - c.foldedCancelledGross;
            owed[3] += sn - c.foldedCancelledNet;
        }

        uint256[4] memory bucketLevel =
            [uint256(b.fulfilledAssets), uint256(b.fulfilledShares), uint256(b.cancelledGross), b.cancelledNet];
        for (uint256 k; k < 4; k++) {
            require(settledSum[k] <= bucketLevel[k], "slices exceed the bucket-level amount");
            require(owed[k] <= bucketLevel[k], "more owed than the bucket settled");
            if (s.outstanding(lid) == 0) {
                require(owed[k] + ghostParts[lid] >= bucketLevel[k], "more dust than one unit per stake");
            }
        }
    }

    function _checkRetirement(uint96 lid) internal view {
        Bucket storage b = s.buckets[lid];
        if (b.total == 0 || ghostShared[lid] || s.outstanding(lid) != 0) return;
        require(_stakes(lid) != 0, "a fully settled, fully folded bucket was not retired");
    }

    function _checkSettlementCount(uint96 lid) internal view {
        Bucket storage b = s.buckets[lid];
        require(b.settlements >= ghostMaxSettlements[lid], "the settlement count went backwards");
        for (uint256 a; a < actors.length; a++) {
            Contribution storage c = s.contributions[lid][actors[a]];
            if (c.amount == 0 || c.foldedSettlements != b.settlements) continue;
            require(s.outstanding(lid) != 0, "a spent contribution can no longer retire");
            (uint128 sa, uint128 ss, uint128 sc, uint128 sn) = s.settled(lid, actors[a]);
            require(c.foldedAssets == sa, "skipped an unfolded asset slice");
            require(c.foldedShares == ss, "skipped an unfolded share slice");
            require(c.foldedCancelledGross == sc, "skipped an unfolded cancellation");
            require(c.foldedCancelledNet == sn, "skipped an unfolded net cancellation");
        }
    }

    function checkHorizon() external view {
        for (uint256 a; a < actors.length; a++) {
            for (uint256 side; side < 2; side++) {
                bool isDeposit = side == 0;
                uint96[] memory ids = h.entries(s, actors[a], isDeposit);
                require(ids.length <= HORIZON, "horizon beyond its size");
                // The controller's slot holds two entries and overflow slot j four after them, so exactly
                // (ids.length + 1) / 4 slots are in use
                for (uint256 j; j < HORIZON; j++) {
                    require(
                        (h.more[actors[a]][isDeposit][j] != 0) == (j < (ids.length + 1) / 4),
                        "the overflow holds more than the entries after the first"
                    );
                }
                for (uint256 i; i < ids.length; i++) {
                    for (uint256 j = i + 1; j < ids.length; j++) {
                        require(ids[i] != ids[j], "an id is in the horizon twice");
                    }
                }
            }
        }
    }

    function checkAggregates() external view {
        for (uint256 a; a < actors.length; a++) {
            address who = actors[a];
            UnfoldedState memory expected = _sumOf(who);
            UnfoldedState memory u = h.unfolded(s, _ledgers[who], who);
            require(u.depositShares == expected.depositShares, "unfolded deposit shares");
            require(u.depositAssets == expected.depositAssets, "unfolded deposit assets");
            require(u.redeemShares == expected.redeemShares, "unfolded redeem shares");
            require(u.redeemAssets == expected.redeemAssets, "unfolded redeem assets");
            require(u.refundShares == expected.refundShares, "unfolded refund shares");
            require(u.refundAssets == expected.refundAssets, "unfolded refund assets");
            require(u.depositPending == expected.depositPending, "deposit pending");
            require(u.redeemPending == expected.redeemPending, "redeem pending");
        }
    }

    /// @dev The pending totals recomputed from every live bucket, less the horizon's settled slices,
    ///      and the horizon's unfolded credits, recomputed from its entries.
    function _sumOf(address who) internal view returns (UnfoldedState memory u) {
        for (uint256 i; i < live.length; i++) {
            uint96 lid = live[i];
            if (s.contributions[lid][who].amount == 0) continue;
            if (s.buckets[lid].isDeposit) u.depositPending += _remainder(lid, who);
            else u.redeemPending += _remainder(lid, who);
        }
        for (uint256 side; side < 2; side++) {
            uint96[] memory ids = h.entries(s, who, side == 0);
            for (uint256 i; i < ids.length; i++) {
                // An id reused on the other side since it entered is stale, and counted nowhere.
                if (s.buckets[ids[i]].isDeposit != (side == 0)) continue;
                _addEntry(ids[i], who, u);
            }
        }
    }

    /// @dev Returns what of the entry is still pending once the fold has run: all of it as of the last fold when the
    ///      fold is deferred for want of room, what is left after its settled slice otherwise.
    function _addEntry(uint96 lid, address who, UnfoldedState memory u) internal view returns (uint128) {
        Contribution storage c = s.contributions[lid][who];
        if (c.amount == 0) return 0;
        (uint128 sa, uint128 ss,, uint128 sn) = s.settled(lid, who);
        uint128 settledPart = _remainder(lid, who) - s.pendingNow(lid, who);
        if (!_fitsLedger(who, lid, u, sa - c.foldedAssets, ss - c.foldedShares, sn - c.foldedCancelledNet)) {
            return s.pendingAtFold(lid, who);
        }
        // A slice counts only when its ledger's unit is non-zero, which is all the vault credits.
        if (s.buckets[lid].isDeposit) {
            if (ss != c.foldedShares) {
                u.depositShares += ss - c.foldedShares;
                u.depositAssets += sa - c.foldedAssets;
            }
            u.depositPending -= settledPart;
            u.refundAssets += sn - c.foldedCancelledNet;
        } else {
            if (sa != c.foldedAssets) {
                u.redeemShares += ss - c.foldedShares;
                u.redeemAssets += sa - c.foldedAssets;
            }
            u.redeemPending -= settledPart;
            u.refundShares += sn - c.foldedCancelledNet;
        }
        return s.pendingNow(lid, who);
    }

    /// @dev Whether the credit still fits the ledger's `uint128` counters on top of what is already counted for the
    ///      controller: the reference for the entries a fold defers and a view leaves out.
    function _fitsLedger(address who, uint96 lid, UnfoldedState memory u, uint128 assets, uint128 shares, uint128 net)
        internal
        view
        returns (bool)
    {
        uint256 max = type(uint128).max;
        InvestmentState storage l = _ledgers[who];
        if (s.buckets[lid].isDeposit) {
            if (
                shares != 0
                    && (uint256(l.depositShares) + u.depositShares + shares > max
                        || uint256(l.depositAssets) + u.depositAssets + assets > max)
            ) return false;
            return net == 0 || uint256(l.refundAssets) + u.refundAssets + net <= max;
        }
        if (
            assets != 0
                && (uint256(l.redeemAssets) + u.redeemAssets + assets > max
                    || uint256(l.redeemShares) + u.redeemShares + shares > max)
        ) return false;
        return net == 0 || uint256(l.refundShares) + u.refundShares + net <= max;
    }

    function _remainder(uint96 lid, address who) internal view returns (uint128) {
        Contribution storage c = s.contributions[lid][who];
        uint128 folded = (s.buckets[lid].isDeposit ? c.foldedAssets : c.foldedShares) + c.foldedCancelledGross;
        return c.amount > folded ? c.amount - folded : 0;
    }

    /// @dev Invariant 4: each pending total is exactly the sum of that controller's remainders.
    function checkPendingTotals() external view {
        for (uint256 a; a < actors.length; a++) {
            for (uint256 side; side < 2; side++) {
                bool isDeposit = side == 0;
                uint256 sum;
                for (uint256 i; i < live.length; i++) {
                    if (s.buckets[live[i]].isDeposit != isDeposit) continue;
                    sum += _remainder(live[i], actors[a]);
                }
                require(s.sides[actors[a]][isDeposit].pending == sum, "a pending total drifted");
            }
        }
    }

    //----------------------------------------------------------------------------------------------
    // Views
    //----------------------------------------------------------------------------------------------

    function bucketOf(uint96 lid) external view returns (Bucket memory) {
        return s.buckets[lid];
    }

    function outstandingOf(uint96 lid) external view returns (uint128) {
        return s.outstanding(lid);
    }

    function contributionOf(uint96 lid, address who) external view returns (Contribution memory) {
        return s.contributions[lid][who];
    }

    function logStats() external view {
        bytes4[11] memory sels = [
            this.contribute.selector,
            this.contributeMany.selector,
            this.flush.selector,
            this.settle.selector,
            this.settleRest.selector,
            this.cancel.selector,
            this.fold.selector,
            this.foldRecent.selector,
            this.transfer.selector,
            this.primeLedger.selector,
            this.claimLedger.selector
        ];
        string[11] memory names = [
            "contribute",
            "contributeMany",
            "flush",
            "settle",
            "settleRest",
            "cancel",
            "fold",
            "foldRecent",
            "transfer",
            "primeLedger",
            "claimLedger"
        ];
        for (uint256 i; i < sels.length; i++) {
            console.log(names[i], succeeded[sels[i]], rejected[sels[i]]);
        }
        console.log("ids / live / dead", nonce, live.length, deadBuckets);
        console.log("spent / retired / reused", spentBuckets, retirements, reuses);
        console.log("shared settlements / transfers", sharedSettlements, transfers);
        console.log("evictions / untracked", evictions, untracked);
    }
}

/// @dev The invariants `BucketLib` names as its own spec, plus conservation, the pending totals and the
///      horizon, checked over arbitrary sequences rather than the fixed orderings the unit tests walk.
///      The concrete suites below pick the shape: many contributors for sharing and dust, few for a
///      horizon that keeps evicting.
abstract contract BucketInvariantsBase is Test {
    BucketHandler handler;

    function _actors() internal pure virtual returns (uint256);

    /// @dev The ceiling of a bucket's denominator and each settled leg. The default keeps what a controller could
    ///      hold inside what a `uint128` can sum; the extreme suite lifts it to the type's maximum.
    function _cap() internal pure virtual returns (uint128) {
        return type(uint128).max / 256;
    }

    /// @dev Whether the burst action that fills a horizon is in the mix. It is what reaches eviction
    ///      quickly, and it also floods the live set, so only the horizon suite takes it.
    function _bursts() internal pure virtual returns (bool);

    function setUp() public {
        handler = new BucketHandler(_actors(), _cap());
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](_bursts() ? 11 : 10);
        selectors[0] = handler.contribute.selector;
        selectors[1] = handler.flush.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.settleRest.selector;
        selectors[4] = handler.cancel.selector;
        selectors[5] = handler.fold.selector;
        selectors[6] = handler.foldRecent.selector;
        selectors[7] = handler.transfer.selector;
        selectors[8] = handler.primeLedger.selector;
        selectors[9] = handler.claimLedger.selector;
        if (_bursts()) selectors[10] = handler.contributeMany.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function afterInvariant() public view {
        handler.logStats();
    }

    /// @dev Folding must never revert: the vault folds the horizon on every claim, and evicts by folding.
    ///      The ledger's counters are pushed to the top of their range by `primeLedger`, so this holds where a
    ///      checked add would have reverted every claim of the controller.
    function invariant_foldNeverReverts() public view {
        assertFalse(handler.foldReverted(), "a fold reverted");
    }

    /// @dev Every other action is refused only with one of the library's own errors, never a panic or an empty
    ///      revert, which the handler would otherwise swallow as an ordinary rejection.
    function invariant_rejectionsAreTheLibrarys() public view {
        assertEq(handler.unexpectedRevert(), "", "an action reverted for a reason the library does not give");
    }

    /// @dev A fold credits exactly the slice it reports and nothing else, one deferred for want of room changes
    ///      nothing, and the views promise exactly what folding the horizon then credits.
    function invariant_aFoldCreditsWhatItReportsAndTheViewsPromise() public view {
        assertEq(handler.creditViolation(), "", "a credit disagreed with what was reported or promised");
    }

    /// @dev Every per-bucket property below also held for each bucket at the moment it died (spent,
    ///      every stake folded out), which is the only time the final dust bound can be checked.
    function invariant_deadBucketsDiedClean() public view {
        assertEq(handler.deadViolation(), "", "a bucket broke a property as it died");
    }

    /// @dev Invariant 1, denominator monotonicity: `total` only grows while the bucket lives (a
    ///      shrinking denominator would inflate every remaining slice of the same fulfillment), and
    ///      it always covers the contributions it divides. Not an equality: a shared bucket keeps its
    ///      `total` when a contributor folds out.
    function invariant_denominator() public view {
        handler.checkDenominator();
    }

    /// @dev What is outstanding covers what is still queued (the over-settlement bound keeps it so),
    ///      which is what makes retiring a spent bucket unable to discard an unflushed top-up.
    function invariant_outstandingCoversTheQueue() public view {
        handler.checkPending();
    }

    /// @dev Invariants 2 and 3 with conservation, per leg (assets, shares, gross and net
    ///      cancellation): no folded snapshot runs ahead of what has settled for it, no contributor is
    ///      pending more than they put in, the floor slices never exceed the bucket-level amount, and
    ///      what was folded out (ghost) plus what is settled but unfolded never exceeds it either.
    ///      Once the bucket is spent the shortfall is at most one unit per stake that ever held part
    ///      of it, one floor each.
    function invariant_conservation() public view {
        handler.checkConservation();
    }

    /// @dev Cleanup: a never-shared bucket with nothing pending and its stake folded out is retired,
    ///      so a policy deriving a permanent local id (`PerInvestorPolicy`) can reuse it. A bucket that
    ///      ever held two stakes keeps its totals, since contributors that have not folded yet still
    ///      measure their slice against them.
    function invariant_settledBucketsAreRetired() public view {
        handler.checkRetirement();
    }

    /// @dev Invariant 6: the count only moves forward, an up-to-date count means nothing to fold, and
    ///      the skip cannot strand a spent contribution (only `settle` reduces `pending`, and it bumps).
    function invariant_theSettlementCountIsASoundSkip() public view {
        handler.checkSettlementCount();
    }

    /// @dev Invariants 4 and 5: the pending totals are exactly the sum of the remainders, and the horizon holds
    ///      no id twice, nothing on the wrong side, and no more than its size.
    function invariant_thePendingTotalsAndHorizonAreExact() public view {
        handler.checkPendingTotals();
        handler.checkHorizon();
    }

    /// @dev A transfer moves only the sender's unsettled remainder: a sender whose settled slice is still unfolded,
    ///      as when its fold was deferred for want of ledger room, cannot move it to the recipient.
    function invariant_aTransferMovesOnlyTheUnsettledRemainder() public view {
        assertEq(handler.staleTransfers(), 0, "a transfer moved the sender's settled slice");
    }

    /// @dev `unfolded` agrees with a from-scratch sum over the live buckets and the
    ///      horizon's entries, which is what makes them safe to drive the views and routing from.
    function invariant_theAggregateViewsMatchThePerBucketOnes() public view {
        handler.checkAggregates();
    }

    function _checkAll() internal view {
        invariant_foldNeverReverts();
        invariant_rejectionsAreTheLibrarys();
        invariant_aFoldCreditsWhatItReportsAndTheViewsPromise();
        invariant_deadBucketsDiedClean();
        invariant_denominator();
        invariant_outstandingCoversTheQueue();
        invariant_conservation();
        invariant_aTransferMovesOnlyTheUnsettledRemainder();
        invariant_settledBucketsAreRetired();
        invariant_theSettlementCountIsASoundSkip();
        invariant_thePendingTotalsAndHorizonAreExact();
        invariant_theAggregateViewsMatchThePerBucketOnes();
    }
}

/// @dev Six contributors: sharing, transfers, dust and retirement.
contract BucketLibInvariantsTest is BucketInvariantsBase {
    function _actors() internal pure override returns (uint256) {
        return 6;
    }

    function _bursts() internal pure override returns (bool) {
        return false;
    }

    /// @dev The properties above are trivially true of an untouched library, and a random sequence is
    ///      not guaranteed to reach the states they bound. This walks the same handler through a
    ///      shared bucket that settles, folds, transfers and dies, and a sole-owner bucket that retires
    ///      and is reused, then checks every invariant over the result.
    function testTheInvariantsAreNotVacuous() public {
        // id 1: shared, partially then fully settled with a fee-bearing cancellation
        handler.contribute(0, 0, 48, 1e18 << 8 | 18);
        handler.contribute(1, 4, 48, 3e18 << 8 | 19);
        handler.flush(0);
        handler.settle(0, 1e18 << 8 | 18, 7e17 << 8 | 18);
        handler.fold(0, 0);
        handler.transfer(1, 2, 0);
        handler.settleRest(0, 2, 5e17 << 8 | 18, 1);
        handler.foldRecent(0);
        handler.foldRecent(2);
        assertEq(handler.outstandingOf(1), 0, "the shared bucket is spent");
        assertTrue(handler.ghostShared(1), "and was shared");
        assertGt(handler.ghostFolded(1)[0], 0, "and its slices folded out");
        assertGt(handler.transfers(), 0, "and a stake moved");
        assertEq(handler.deadBuckets(), 1, "and it died");

        // id 2: sole owner, settles, folds out, retires; the id is reused
        handler.contribute(3, 0, 0, 1e6 << 8 | 6);
        handler.settleRest(0, 0, 1e18 << 8 | 18, 0);
        handler.fold(3, 0);
        assertEq(handler.retirements(), 1, "the sole-owner bucket retired");
        handler.contribute(3, 2 << 3 | 3, 0, 1e6 << 8 | 6);
        assertEq(handler.reuses(), 1, "and its id was reused");

        _checkAll();
    }
}

/// @dev Two controllers whose horizons keep filling and evicting, around retired and reused ids.
contract BucketHorizonInvariantsTest is BucketInvariantsBase {
    function _actors() internal pure override returns (uint256) {
        return 2;
    }

    function _bursts() internal pure override returns (bool) {
        return true;
    }

    function testTheHorizonEvicts() public {
        handler.contributeMany(0, 9, 1);
        assertEq(handler.evictions(), 5, "eight own deposit requests through a horizon of three");
        _checkAll();
    }
}

/// @dev Amounts up to the top of `uint128`, so denominators, settled legs, pending totals and the ledger's counters meet
///      their limits and not just each other's. Every property above must still hold: a request that would overflow
///      is rejected whole, a fold never reverts and defers what does not fit, and the views and the credits agree.
///      This is the suite that would have found a ledger counter's checked add reverting every claim.
contract BucketLibExtremeInvariantsTest is BucketInvariantsBase {
    function _actors() internal pure override returns (uint256) {
        return 4;
    }

    function _bursts() internal pure override returns (bool) {
        return false;
    }

    function _cap() internal pure override returns (uint128) {
        return type(uint128).max;
    }
}
