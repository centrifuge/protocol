// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC7575} from "../../../../src/misc/interfaces/IERC7575.sol";
import {IERC7540Deposit, IERC7540Redeem} from "../../../../src/misc/interfaces/IERC7540.sol";

import {IEscrow} from "../../../../src/core/spoke/interfaces/IEscrow.sol";

import {IVaultEvents, REASON_DEPOSIT, REASON_REDEEM} from "../../../../src/vaults/interfaces/IAsyncVault.sol";

import {VmSafe} from "forge-std/Vm.sol";

/// @notice A reference indexer of the vault: a state machine that rebuilds every request, bucket and claimable
///         ledger from the vault's logs alone, the way an off-chain indexer would, and records an anomaly wherever a
///         log contradicts the state its predecessors built or leaves a gap only a storage read could fill.
/// @dev    It reads no vault state. Besides the vault's logs it follows the escrow's `DecreaseReserve` and
///         `IncreaseReserve` made for a followed vault, the one place a settlement's release out of a deposit
///         request's reservation and its payout reservation are visible. A contributor's slice of a shared bucket is
///         the closed form `floor(fulfilled * contribution / total)`, which is how the vault derives it lazily, so
///         what a fold has not yet applied is computed here from the bucket and the contribution. Recording rather
///         than reverting keeps a mismatch reportable by the suite's checks. Plain Solidity with no dependency on the
///         suite, so a test of another vault can reuse it by registering the vault and feeding it
///         `vm.getRecordedLogs()`.
contract VaultIndexer {
    struct Bucket {
        bool isDeposit;
        bool flushed;
        /// @dev `BucketOpened` seen, first contribution not yet
        bool opened;
        uint128 total;
        uint128 queued;
        /// @dev Everything flushed so far, so `sent + queued == total`
        uint128 sent;
        uint128 fulfilledAssets;
        uint128 fulfilledShares;
        uint128 cancelledGross;
        uint128 cancelledNet;
        uint32 settlements;
    }

    struct Position {
        uint128 amount;
        uint32 foldedSettlements;
        uint128 foldedAssets;
        uint128 foldedShares;
        uint128 foldedCancelledGross;
        uint128 foldedCancelledNet;
    }

    struct Ledger {
        uint128 maxMint;
        uint128 depositAssets;
        uint128 maxWithdraw;
        uint128 redeemShares;
        uint128 refundShares;
        uint128 refundAssets;
        /// @dev What `Claimed` paid out, in shares on the deposit side and assets on the redeem side
        uint256 claimedShares;
        uint256 claimedAssets;
    }

    /// @dev A slice of a contribution settled so far, as `BucketLib` computes it.
    struct Slice {
        uint128 assets;
        uint128 shares;
        uint128 cancelledGross;
        uint128 cancelledNet;
    }

    /// @dev An ERC-4626 event waiting for the event that says what trade it was.
    struct Standard {
        bool set;
        bool isDeposit;
        address sender;
        address receiver;
        address owner;
        uint128 assets;
        uint128 shares;
    }

    /// @dev The credit events of the fold in progress, closed by its `RequestFolded`.
    struct Credit {
        bool set;
        uint256 requestId;
        address controller;
        uint128 assets;
        uint128 shares;
        uint128 refund;
    }

    /// @dev What the escrow logged for a vault since the vault's last own event, which the next `BucketSettled`
    ///      accounts for: a release out of a deposit request's reservation and the payout reserved.
    struct Escrowed {
        bool released;
        uint96 releasedId;
        uint128 release;
        uint128 payout;
    }

    struct Anomaly {
        string what;
        uint256 got;
        uint256 want;
    }

    /// @dev Every event kind the indexer handles, for the suite's non-vacuity counters.
    enum Kind {
        Request,
        Opened,
        Flush,
        BucketSettled,
        Released,
        PayoutReserved,
        Folded,
        FoldedCompleted,
        FoldedRetired,
        FoldedShared,
        DepositClaimable,
        RedeemClaimable,
        CancelDepositClaimable,
        CancelRedeemClaimable,
        Transferred,
        Claimed,
        ClaimedRefund,
        InstantFees,
        Offer,
        StandardEvent
    }

    uint256 internal constant KINDS = 20;

    uint256[KINDS] public seen;
    Anomaly[] internal _anomalies;

    address[] internal _vaults;
    mapping(address vault => bool) public isVault;
    mapping(address vault => uint256[]) internal _requestIds;
    mapping(address vault => mapping(uint256 requestId => bool)) internal _knownRequest;
    mapping(address vault => address[]) internal _controllers;
    mapping(address vault => mapping(address controller => bool)) internal _knownController;
    mapping(address vault => mapping(uint256 requestId => address[])) internal _holders;
    mapping(address vault => mapping(uint256 requestId => mapping(address controller => bool))) internal _held;

    mapping(address vault => mapping(uint256 requestId => Bucket)) internal _buckets;
    mapping(address vault => mapping(uint256 requestId => mapping(address controller => Position))) internal _positions;
    mapping(address vault => mapping(address controller => Ledger)) internal _ledgers;

    /// @dev The deposit reservation per request id, and the redeem payout reservation per vault.
    mapping(address vault => mapping(uint96 localId => uint256)) internal _reservedDeposit;
    mapping(address vault => uint256) public reservedRedeem;

    /// @dev What the escrow released out of a request's reservation on its fills, in all
    mapping(address vault => mapping(uint96 localId => uint256)) internal _approved;
    /// @dev The deposit request a reservation reason belongs to, plus one
    mapping(address vault => mapping(bytes32 reason => uint256)) internal _depositIdOf;

    /// @dev What a vault with a liquidity route must have offered it: every released approval and every instant
    ///      deposit's escrowed assets.
    mapping(address vault => uint256) public offered;
    mapping(address vault => uint256) public expectedOffer;

    mapping(address vault => Standard) internal _standard;
    mapping(address vault => Credit) internal _credit;
    mapping(address vault => Escrowed) internal _escrowed;

    /// @notice Starts following `vault`: its logs are consumed, every other emitter's are ignored.
    function register(address vault) external {
        if (isVault[vault]) return;
        isVault[vault] = true;
        _vaults.push(vault);
    }

    //----------------------------------------------------------------------------------------------
    // Reads
    //----------------------------------------------------------------------------------------------

    function anomalyCount() external view returns (uint256) {
        return _anomalies.length;
    }

    function anomaly(uint256 i) external view returns (Anomaly memory) {
        return _anomalies[i];
    }

    function requestIds(address vault) external view returns (uint256[] memory) {
        return _requestIds[vault];
    }

    function controllers(address vault) external view returns (address[] memory) {
        return _controllers[vault];
    }

    function holders(address vault, uint256 requestId) external view returns (address[] memory) {
        return _holders[vault][requestId];
    }

    function bucketOf(address vault, uint256 requestId) external view returns (Bucket memory) {
        return _buckets[vault][requestId];
    }

    function position(address vault, uint256 requestId, address controller) external view returns (Position memory) {
        return _positions[vault][requestId][controller];
    }

    function ledgerOf(address vault, address controller) external view returns (Ledger memory) {
        return _ledgers[vault][controller];
    }

    function approvedOf(address vault, uint256 requestId) external view returns (uint256) {
        return _approved[vault][uint96(requestId)];
    }

    function reservedDepositOf(address vault, uint256 requestId) external view returns (uint256) {
        return _reservedDeposit[vault][uint96(requestId)];
    }

    /// @notice What a contributor has outstanding in the bucket as of its last fold: contributed less the folded
    ///         fill and cancellation.
    function pendingAtFold(address vault, uint256 requestId, address controller) public view returns (uint128) {
        Bucket storage b = _buckets[vault][requestId];
        Position storage p = _positions[vault][requestId][controller];
        return _pendingAtFold(b, p);
    }

    /// @notice What a contributor has outstanding with every settlement so far applied, closed form.
    function pendingNow(address vault, uint256 requestId, address controller) public view returns (uint128) {
        Bucket storage b = _buckets[vault][requestId];
        Position storage p = _positions[vault][requestId][controller];
        if (p.amount == 0) return 0;
        if (p.foldedSettlements == b.settlements) return _pendingAtFold(b, p);
        if (_outstanding(b) == 0) return 0;
        Slice memory s = slice(b, p.amount);
        return _sat(p.amount, (b.isDeposit ? s.assets : s.shares) + s.cancelledGross);
    }

    /// @notice A contributor's settled slice of a bucket: the whole bucket for a sole owner, otherwise each
    ///         amount's `floor(amount * contribution / total)`.
    function slice(Bucket memory b, uint128 contributed) public pure returns (Slice memory s) {
        if (contributed == 0) return s;
        if (contributed == b.total) {
            return Slice(b.fulfilledAssets, b.fulfilledShares, b.cancelledGross, b.cancelledNet);
        }
        s.assets = uint128(uint256(b.fulfilledAssets) * contributed / b.total);
        s.shares = uint128(uint256(b.fulfilledShares) * contributed / b.total);
        s.cancelledGross = uint128(uint256(b.cancelledGross) * contributed / b.total);
        s.cancelledNet = uint128(uint256(b.cancelledNet) * contributed / b.total);
    }

    /// @dev What folding every position of a controller would add to its ledger.
    struct Unfolded {
        uint256 mintable;
        uint256 withdrawable;
        uint256 depositAssets;
        uint256 redeemShares;
    }

    /// @notice What folding every position of `controller` would add to its ledger, closed form: shares to mint and
    ///         assets to withdraw (refunds included, as the claimable views sum them), and the filled legs.
    function unfolded(address vault, address controller) external view returns (Unfolded memory u) {
        uint256[] storage ids = _requestIds[vault];
        for (uint256 i; i < ids.length; i++) {
            _addUnfolded(_buckets[vault][ids[i]], _positions[vault][ids[i]][controller], u);
        }
    }

    function _addUnfolded(Bucket storage b, Position storage p, Unfolded memory u) internal view {
        if (p.amount == 0 || p.foldedSettlements == b.settlements) return;
        Slice memory s = slice(b, p.amount);
        uint256 refund = s.cancelledNet - p.foldedCancelledNet;
        if (b.isDeposit) {
            if (s.shares > p.foldedShares) {
                u.mintable += s.shares - p.foldedShares;
                u.depositAssets += s.assets - p.foldedAssets;
            }
            u.withdrawable += refund;
        } else {
            if (s.assets > p.foldedAssets) {
                u.withdrawable += s.assets - p.foldedAssets;
                u.redeemShares += s.shares - p.foldedShares;
            }
            u.mintable += refund;
        }
    }

    //----------------------------------------------------------------------------------------------
    // Consumption
    //----------------------------------------------------------------------------------------------

    /// @notice Applies the logs in order. A log of an unregistered emitter or an event the indexer does not follow
    ///         is skipped.
    function consume(VmSafe.Log[] memory logs) external {
        for (uint256 i; i < logs.length; i++) {
            VmSafe.Log memory l = logs[i];
            // The first anomaly is the cause: what follows reads a state the replay no longer has
            if (_anomalies.length != 0) break;
            if (l.topics.length == 0) continue;
            if (l.topics[0] == IEscrow.DecreaseReserve.selector || l.topics[0] == IEscrow.IncreaseReserve.selector) {
                _reservation(l.topics[0] == IEscrow.IncreaseReserve.selector, l.data);
                continue;
            }
            if (!isVault[l.emitter]) continue;
            // What the escrow logged is the vault's last callback's, so a vault event ends it unless it accounts
            // for it
            bytes32 id = l.topics[0];
            if (id != IVaultEvents.BucketSettled.selector && id != IVaultEvents.ForwardedToRoute.selector) {
                delete _escrowed[l.emitter];
            }
            _apply(l.emitter, l.topics, l.data);
        }
        for (uint256 i; i < _vaults.length; i++) {
            if (_standard[_vaults[i]].set) _flag("an ERC-4626 event had no Claimed or InstantFees beside it", 0, 0);
            delete _standard[_vaults[i]];
        }
    }

    function _apply(address v, bytes32[] memory t, bytes memory d) internal {
        bytes32 id = t[0];
        if (id == IERC7540Deposit.DepositRequest.selector) {
            (, uint256 assets) = abi.decode(d, (address, uint256));
            _request(v, uint256(t[3]), _addr(t[1]), true, uint128(assets));
        } else if (id == IERC7540Redeem.RedeemRequest.selector) {
            (, uint256 shares) = abi.decode(d, (address, uint256));
            _request(v, uint256(t[3]), _addr(t[1]), false, uint128(shares));
        } else if (id == IVaultEvents.BucketOpened.selector) {
            (bool isDeposit,) = abi.decode(d, (bool, bytes32));
            _opened(v, uint256(t[1]), isDeposit);
        } else if (id == IVaultEvents.RequestFlushed.selector) {
            (bool isDeposit, uint128 amount) = abi.decode(d, (bool, uint128));
            _flush(v, uint256(t[1]), isDeposit, amount);
        } else if (id == IVaultEvents.BucketSettled.selector) {
            _settleBucket(v, uint256(t[1]), d);
        } else if (id == IVaultEvents.RequestFolded.selector) {
            _folded(v, uint256(t[1]), _addr(t[2]), d);
        } else if (id == IVaultEvents.DepositClaimable.selector) {
            _claimable(v, uint256(t[1]), _addr(t[2]), true, d);
        } else if (id == IVaultEvents.RedeemClaimable.selector) {
            _claimable(v, uint256(t[1]), _addr(t[2]), false, d);
        } else if (id == IVaultEvents.CancelDepositClaimable.selector) {
            _refund(v, uint256(t[1]), _addr(t[2]), true, abi.decode(d, (uint128)));
        } else if (id == IVaultEvents.CancelRedeemClaimable.selector) {
            _refund(v, uint256(t[1]), _addr(t[2]), false, abi.decode(d, (uint128)));
        } else if (id == IVaultEvents.RequestTransferred.selector) {
            _transferred(v, uint256(t[1]), _addr(t[2]), _addr(t[3]), d);
        } else if (id == IVaultEvents.Claimed.selector) {
            _claimed(v, _addr(t[1]), _addr(t[2]), d);
        } else if (id == IVaultEvents.InstantFees.selector) {
            _instant(v, _addr(t[2]), _addr(t[1]), d);
        } else if (id == IVaultEvents.ForwardedToRoute.selector) {
            seen[uint256(Kind.Offer)]++;
            uint128 forwarded = abi.decode(d, (uint128));
            Escrowed storage e = _escrowed[v];
            if (e.released && forwarded != e.release) {
                _flag("ForwardedToRoute != the approval's release before it", forwarded, e.release);
            }
            offered[v] += forwarded;
        } else if (id == IERC7575.Deposit.selector) {
            _standardEvent(v, true, _addr(t[1]), address(0), _addr(t[2]), d);
        } else if (id == IERC7575.Withdraw.selector) {
            _standardEvent(v, false, _addr(t[1]), _addr(t[2]), _addr(t[3]), d);
        }
    }

    function _addr(bytes32 topic) internal pure returns (address) {
        return address(uint160(uint256(topic)));
    }

    //----------------------------------------------------------------------------------------------
    // Requests and buckets
    //----------------------------------------------------------------------------------------------

    function _knowController(address v, address controller) internal {
        if (_knownController[v][controller]) return;
        _knownController[v][controller] = true;
        _controllers[v].push(controller);
    }

    function _know(address v, uint256 requestId, address controller) internal {
        if (!_knownRequest[v][requestId]) {
            _knownRequest[v][requestId] = true;
            _requestIds[v].push(requestId);
        }
        _knowController(v, controller);
        if (!_held[v][requestId][controller]) {
            _held[v][requestId][controller] = true;
            _holders[v][requestId].push(controller);
        }
    }

    function _opened(address v, uint256 requestId, bool isDeposit) internal {
        seen[uint256(Kind.Opened)]++;
        Bucket storage b = _buckets[v][requestId];
        if (b.total != 0) _flag("BucketOpened on a bucket the replay holds contributions in", b.total, 0);
        b.opened = true;
        b.isDeposit = isDeposit;
    }

    function _request(address v, uint256 requestId, address controller, bool isDeposit, uint128 amount) internal {
        seen[uint256(Kind.Request)]++;
        _know(v, requestId, controller);
        Bucket storage b = _buckets[v][requestId];
        if (b.total == 0 && !b.opened) _flag("a request filled an empty bucket with no BucketOpened", requestId, 0);
        if (b.isDeposit != isDeposit) _flag("a request's side differs from its bucket's", isDeposit ? 1 : 0, 0);
        b.opened = false;
        b.total += amount;
        b.queued += amount;
        _positions[v][requestId][controller].amount += amount;
        if (isDeposit) {
            _reservedDeposit[v][uint96(requestId)] += amount;
            _depositIdOf[v][keccak256(abi.encode(REASON_DEPOSIT, uint96(requestId)))] = uint256(uint96(requestId)) + 1;
        }
    }

    /// @dev The data of the escrow's `IncreaseReserve` and `DecreaseReserve`.
    struct Reserve {
        bytes16 scId;
        address caller;
        bytes32 reason;
        uint128 delta;
        uint128 value;
    }

    /// @dev A release under a known deposit request's reason, or a reservation of the redeem payout, made for a
    ///      followed vault. The next `BucketSettled` accounts for it.
    function _reservation(bool increase, bytes memory d) internal {
        Reserve memory r = abi.decode(d, (Reserve));
        if (!isVault[r.caller]) return;
        Escrowed storage e = _escrowed[r.caller];
        uint256 id = _depositIdOf[r.caller][r.reason];
        if (!increase && id != 0) {
            // A later release overwrites an earlier one: a manager's unreserve has no event of the vault after it
            e.released = true;
            e.releasedId = uint96(id - 1);
            e.release = r.delta;
        } else if (increase && r.reason == REASON_REDEEM) {
            e.payout += r.delta;
        }
    }

    function _flush(address v, uint256 requestId, bool isDeposit, uint128 amount) internal {
        seen[uint256(Kind.Flush)]++;
        Bucket storage b = _buckets[v][requestId];
        if (b.isDeposit != isDeposit) _flag("RequestFlushed names the other side than the bucket's", 0, 0);
        if (amount != b.queued) _flag("RequestFlushed.amount != the replayed queue", amount, b.queued);
        b.sent += amount;
        b.queued = 0;
        b.flushed = true;
    }

    function _settleBucket(address v, uint256 requestId, bytes memory d) internal {
        seen[uint256(Kind.BucketSettled)]++;
        (bool isDeposit, uint128 assets, uint128 shares, uint128 gross, uint128 net) =
            abi.decode(d, (bool, uint128, uint128, uint128, uint128));
        Bucket storage b = _buckets[v][requestId];
        if (b.isDeposit != isDeposit) _flag("BucketSettled names the other side than the bucket's", 0, 0);
        if (!b.flushed) _flag("BucketSettled on a bucket the replay holds unflushed", requestId, 0);
        if (assets != 0) {
            b.fulfilledAssets += assets;
            b.fulfilledShares += shares;
        }
        if (gross != 0 || net != 0) {
            b.cancelledGross += gross;
            b.cancelledNet += net;
        }
        b.settlements++;
        if (_outstanding(b) > b.total) _flag("a bucket settled more than it holds", 0, 0);
        _settleReservations(v, uint96(requestId), isDeposit, assets, gross, net);
        delete _escrowed[v];
    }

    /// @dev What the escrow logged for the settlement, against the replay. A deposit fill or cancellation releases
    ///      out of the request's reservation, clamped to what it still has: the release is the escrow's, since a
    ///      manager's early unreserve is no event of the vault, and only a cancellation's is replayed exactly. A
    ///      redeem fill reserves its assets as the payout and a deposit cancellation its net.
    function _settleReservations(address v, uint96 localId, bool isDeposit, uint128 assets, uint128 gross, uint128 net)
        internal
    {
        Escrowed storage e = _escrowed[v];
        uint256 payout = isDeposit ? (gross != 0 ? net : 0) : assets;
        if (e.payout != payout) _flag("the escrow's payout reservation != the settlement's", e.payout, payout);
        if (payout != 0) seen[uint256(Kind.PayoutReserved)]++;
        reservedRedeem[v] += payout;
        if (!isDeposit) {
            if (e.released) _flag("a redeem settlement released a deposit reservation", e.release, 0);
            return;
        }

        if (e.released && e.releasedId != localId) {
            _flag("a release under another request's reason", e.releasedId, localId);
        }
        uint256 release = e.released ? e.release : 0;
        uint256 reserved = _reservedDeposit[v][localId];
        uint256 settled = assets != 0 ? assets : gross;
        uint256 clamped = settled < reserved ? settled : reserved;
        if (release > clamped) {
            _flag("the escrow released more than the settlement and the replay allow", release, clamped);
        }
        if (gross != 0 && release != clamped) {
            _flag("a cancellation's release != the replayed clamp", release, clamped);
        }
        if (release != 0) seen[uint256(Kind.Released)]++;
        _reservedDeposit[v][localId] = _sat(reserved, release);
        if (assets != 0) {
            _approved[v][localId] += release;
            expectedOffer[v] += release;
        }
    }

    //----------------------------------------------------------------------------------------------
    // Folds and credits
    //----------------------------------------------------------------------------------------------

    function _claimable(address v, uint256 requestId, address controller, bool isDeposit, bytes memory d) internal {
        (uint128 assets, uint128 shares) = abi.decode(d, (uint128, uint128));
        Ledger storage l = _ledgers[v][controller];
        Credit storage c = _credit[v];
        if (isDeposit) {
            seen[uint256(Kind.DepositClaimable)]++;
            l.maxMint += shares;
            l.depositAssets += assets;
        } else {
            seen[uint256(Kind.RedeemClaimable)]++;
            l.maxWithdraw += assets;
            l.redeemShares += shares;
        }
        _openCredit(c, requestId, controller);
        c.assets += assets;
        c.shares += shares;
    }

    function _refund(address v, uint256 requestId, address controller, bool isDeposit, uint128 amount) internal {
        Ledger storage l = _ledgers[v][controller];
        if (isDeposit) {
            seen[uint256(Kind.CancelDepositClaimable)]++;
            l.refundAssets += amount;
        } else {
            seen[uint256(Kind.CancelRedeemClaimable)]++;
            l.refundShares += amount;
        }
        Credit storage c = _credit[v];
        _openCredit(c, requestId, controller);
        c.refund += amount;
    }

    function _openCredit(Credit storage c, uint256 requestId, address controller) internal {
        if (c.set && (c.requestId != requestId || c.controller != controller)) {
            _flag("a credit event names another fold's request or controller", requestId, c.requestId);
        }
        c.set = true;
        c.requestId = requestId;
        c.controller = controller;
    }

    function _folded(address v, uint256 requestId, address controller, bytes memory d) internal {
        seen[uint256(Kind.Folded)]++;
        Folded memory f = abi.decode(d, (Folded));
        Bucket storage b = _buckets[v][requestId];
        Position storage p = _positions[v][requestId][controller];
        _know(v, requestId, controller);
        if (p.amount == 0) _flag("RequestFolded for a contributor the replay holds no contribution of", requestId, 0);
        if (p.amount != b.total && (f.assets | f.shares | f.cancelledGross) != 0) seen[uint256(Kind.FoldedShared)]++;
        _checkFold(v, b, p, requestId, controller, f);
        delete _credit[v];

        if (f.completed) {
            seen[uint256(Kind.FoldedCompleted)]++;
            if (_outstanding(b) != 0) _flag("a fold completed a contribution of a bucket the replay holds open", 0, 0);
            if (f.pending != 0) _flag("a completed fold reports pending", f.pending, 0);
            if (f.retired != (p.amount == b.total)) {
                _flag("RequestFolded.retired != sole ownership in the replay", 0, 0);
            }
            if (f.retired) {
                seen[uint256(Kind.FoldedRetired)]++;
                delete _buckets[v][requestId];
            }
            delete _positions[v][requestId][controller];
        } else {
            if (f.retired) _flag("a fold retired a bucket without completing", 0, 0);
            _advance(b, p);
            uint128 expected = _pendingAtFold(b, p);
            if (f.pending != expected) _flag("RequestFolded.pending != the replayed pending", f.pending, expected);
        }
    }

    /// @dev The data of `RequestFolded`, which a static tuple of eight words shares.
    struct Folded {
        bool isDeposit;
        uint128 assets;
        uint128 shares;
        uint128 cancelledGross;
        uint128 cancelledNet;
        uint128 pending;
        bool completed;
        bool retired;
    }

    /// @dev What the fold credited, against the slice the replay computes for the contributor.
    function _checkFold(
        address v,
        Bucket storage b,
        Position storage p,
        uint256 requestId,
        address controller,
        Folded memory f
    ) internal {
        if (f.isDeposit != b.isDeposit) {
            _flag("RequestFolded names the other side than the bucket's", 0, 0);
        }
        Slice memory w = _wanted(b, p);
        if (f.assets != w.assets) _flag("RequestFolded.assets != the closed-form slice", f.assets, w.assets);
        if (f.shares != w.shares) _flag("RequestFolded.shares != the closed-form slice", f.shares, w.shares);
        if (f.cancelledGross != w.cancelledGross) {
            _flag("RequestFolded.cancelledGross != the closed-form slice", f.cancelledGross, w.cancelledGross);
        }
        if (f.cancelledNet != w.cancelledNet) {
            _flag("RequestFolded.cancelledNet != the closed-form slice", f.cancelledNet, w.cancelledNet);
        }

        // The credit events beside it carry exactly what it reports
        Credit storage c = _credit[v];
        if (c.set && (c.requestId != requestId || c.controller != controller)) {
            _flag("the credit events before a fold name another request or controller", 0, 0);
        }
        if (c.assets != f.assets || c.shares != f.shares) {
            _flag("the Claimable event differs from RequestFolded", c.shares, f.shares);
        }
        if (c.refund != f.cancelledNet) {
            _flag("the Cancel*Claimable event differs from RequestFolded", c.refund, f.cancelledNet);
        }
    }

    /// @dev What a fold of the contributor credits now: the settled slice less what it folded already. A slice that
    ///      floors to nothing in the ledger's unit is dust and credits nothing, and the cancellation part is skipped
    ///      without a cancellation.
    function _wanted(Bucket storage b, Position storage p) internal view returns (Slice memory w) {
        Slice memory s = slice(b, p.amount);
        w.assets = s.assets - p.foldedAssets;
        w.shares = s.shares - p.foldedShares;
        if (b.isDeposit ? w.shares == 0 : w.assets == 0) (w.assets, w.shares) = (0, 0);
        if (s.cancelledGross != 0 || s.cancelledNet != 0) {
            w.cancelledGross = s.cancelledGross - p.foldedCancelledGross;
            w.cancelledNet = s.cancelledNet - p.foldedCancelledNet;
        }
    }

    function _advance(Bucket storage b, Position storage p) internal {
        Slice memory s = slice(b, p.amount);
        p.foldedAssets = s.assets;
        p.foldedShares = s.shares;
        if (s.cancelledGross != 0 || s.cancelledNet != 0) {
            p.foldedCancelledGross = s.cancelledGross;
            p.foldedCancelledNet = s.cancelledNet;
        }
        p.foldedSettlements = b.settlements;
    }

    /// @dev The data of `RequestTransferred`, which a static tuple of three words shares.
    struct Moved {
        bool isDeposit;
        uint128 contributed;
        uint128 pending;
    }

    function _transferred(address v, uint256 requestId, address from, address to, bytes memory d) internal {
        seen[uint256(Kind.Transferred)]++;
        _know(v, requestId, to);
        _checkTransfer(v, requestId, from, abi.decode(d, (Moved)));

        Position storage src = _positions[v][requestId][from];
        Position storage dst = _positions[v][requestId][to];
        dst.amount += src.amount;
        dst.foldedAssets += src.foldedAssets;
        dst.foldedShares += src.foldedShares;
        dst.foldedCancelledGross += src.foldedCancelledGross;
        dst.foldedCancelledNet += src.foldedCancelledNet;
        dst.foldedSettlements = 0;
        delete _positions[v][requestId][from];
    }

    /// @dev What the event reports of the sender's position, against the position the replay holds.
    function _checkTransfer(address v, uint256 requestId, address from, Moved memory m) internal {
        Position storage src = _positions[v][requestId][from];
        if (m.isDeposit != _buckets[v][requestId].isDeposit) {
            _flag("RequestTransferred names the other side than the bucket's", 0, 0);
        }
        if (m.contributed != src.amount) {
            _flag("RequestTransferred.contributed != the replayed contribution", m.contributed, src.amount);
        }
        uint128 want = pendingNow(v, requestId, from);
        if (m.pending != want) _flag("RequestTransferred.pending != the replayed pending", m.pending, want);
    }

    //----------------------------------------------------------------------------------------------
    // Claims and instant trades
    //----------------------------------------------------------------------------------------------

    function _standardEvent(address v, bool isDeposit, address sender, address receiver, address owner, bytes memory d)
        internal
    {
        seen[uint256(Kind.StandardEvent)]++;
        (uint256 assets, uint256 shares) = abi.decode(d, (uint256, uint256));
        if (_standard[v].set) _flag("an ERC-4626 event had no Claimed or InstantFees beside it", 0, 0);
        // `Deposit` has no receiver slot: its owner is the receiver
        _standard[v] =
            Standard(true, isDeposit, sender, isDeposit ? owner : receiver, owner, uint128(assets), uint128(shares));
    }

    /// @dev The data of `Claimed`.
    struct Claim {
        address sender;
        bool isDeposit;
        uint128 assets;
        uint128 shares;
        uint128 refund;
    }

    function _claimed(address v, address controller, address receiver, bytes memory d) internal {
        seen[uint256(Kind.Claimed)]++;
        Claim memory c = abi.decode(d, (Claim));
        _knowController(v, controller);
        _matchClaim(v, controller, receiver, c);
        delete _standard[v];
        if (c.refund != 0) seen[uint256(Kind.ClaimedRefund)]++;

        Ledger storage l = _ledgers[v][controller];
        if (c.isDeposit) {
            // Refunded shares come off first and carry no assets, the rest is the filled leg
            if (c.refund > c.shares || c.refund > l.refundShares) {
                _flag("a mint claimed more refund than the replay holds", c.refund, l.refundShares);
            }
            if (c.shares - c.refund > l.maxMint || c.assets > l.depositAssets) {
                _flag("a deposit claim exceeds the replayed ledger", c.shares - c.refund, l.maxMint);
            }
            l.refundShares = _sat(l.refundShares, c.refund);
            l.maxMint = _sat(l.maxMint, c.shares - c.refund);
            l.depositAssets = _sat(l.depositAssets, c.assets);
            l.claimedShares += c.shares;
        } else {
            if (c.refund > c.assets || c.refund > l.refundAssets) {
                _flag("a withdraw claimed more refund than the replay holds", c.refund, l.refundAssets);
            }
            if (c.assets - c.refund > l.maxWithdraw || c.shares > l.redeemShares) {
                _flag("a redeem claim exceeds the replayed ledger", c.assets - c.refund, l.maxWithdraw);
            }
            l.refundAssets = _sat(l.refundAssets, c.refund);
            l.maxWithdraw = _sat(l.maxWithdraw, c.assets - c.refund);
            l.redeemShares = _sat(l.redeemShares, c.shares);
            l.claimedAssets += c.assets;
            _payOut(v, c.assets);
        }
    }

    /// @dev The payout leaves the redeem reservation, refunds included.
    function _payOut(address v, uint128 assets) internal {
        if (assets > reservedRedeem[v]) {
            _flag("a claim paid more than the replayed redeem reservation", assets, reservedRedeem[v]);
        }
        reservedRedeem[v] = _sat(reservedRedeem[v], assets);
    }

    /// @dev `Claimed` has to name the same trade as the ERC-4626 event beside it.
    function _matchClaim(address v, address controller, address receiver, Claim memory c) internal {
        Standard storage s = _standard[v];
        bool same = s.set && s.isDeposit == c.isDeposit && s.assets == c.assets && s.shares == c.shares
            && s.receiver == receiver;
        // The deposit event's sender slot is the controller, the withdraw event's owner slot is
        same = same && (c.isDeposit ? s.sender == controller : s.owner == controller && s.sender == c.sender);
        if (!same) _flag("Claimed does not match the ERC-4626 event beside it", c.assets, s.assets);
    }

    /// @dev The data of `InstantFees`, which a static tuple shares.
    struct Instant {
        bool isDeposit;
        uint128 shares;
        int128 feeAssets;
        address feeRecipient;
        uint128 retainedAssets;
        uint128 routedAssets;
        uint256 pricePoolPerAsset;
        uint256 pricePoolPerShare;
    }

    /// @dev The instant trade's own event has to name the same trade as the ERC-4626 event beside it, with no join
    ///      by log position.
    function _instant(address v, address receiver, address caller, bytes memory d) internal {
        seen[uint256(Kind.InstantFees)]++;
        Instant memory i = abi.decode(d, (Instant));
        Standard storage s = _standard[v];
        bool same =
            s.set && s.isDeposit == i.isDeposit && s.shares == i.shares && s.sender == caller && s.receiver == receiver;
        if (!same) _flag("InstantFees does not match the ERC-4626 event beside it", i.shares, s.shares);
        // The assets a deposit escrowed are what the caller paid less the fee it paid on top
        if (i.isDeposit && s.set) expectedOffer[v] += uint256(int256(uint256(s.assets)) - i.feeAssets);
        delete _standard[v];
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    function _outstanding(Bucket storage b) internal view returns (uint128) {
        return b.total - (b.isDeposit ? b.fulfilledAssets : b.fulfilledShares) - b.cancelledGross;
    }

    function _pendingAtFold(Bucket storage b, Position storage p) internal view returns (uint128) {
        return _sat(p.amount, uint256(b.isDeposit ? p.foldedAssets : p.foldedShares) + p.foldedCancelledGross);
    }

    function _sat(uint256 a, uint256 b) internal pure returns (uint128) {
        return a > b ? uint128(a - b) : 0;
    }

    function _flag(string memory what, uint256 got, uint256 want) internal {
        _anomalies.push(Anomaly(what, got, want));
    }
}
