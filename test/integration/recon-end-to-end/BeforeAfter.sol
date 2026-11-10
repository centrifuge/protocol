// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Setup} from "./Setup.sol";

import {D18} from "../../../src/misc/types/D18.sol";
import {MathLib} from "../../../src/misc/libraries/MathLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../src/core/types/AssetId.sol";
import {AccountId} from "../../../src/core/types/AccountId.sol";
import {RequestId} from "../../../src/core/types/RequestId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";

import {BucketReference} from "../../vaults/BucketReference.sol";

import {IAsyncVault, Bucket, Contribution, REASON_DEPOSIT} from "../../../src/vaults/interfaces/IAsyncVault.sol";

import {vm} from "@chimera/Hevm.sol";

/// @dev What a handler does, for properties that only hold across some kinds of operation.
enum OpType {
    USER, // investors: requests, claims, instant lanes, transfers, keepers flushing and folding
    MANAGER, // pool manager and balance-sheet manager actions that move no price
    PRICE, // repricing, valuation and time
    TERMS // fee, policy and oracle-pause changes: no price moves, but a lane's terms do
}

/// @notice Ghost state and the before/after snapshot every handler takes through `updateGhosts`.
abstract contract BeforeAfter is Setup {
    /// @dev The selector of `Panic(uint256)`: a failed `assert`, or checked arithmetic that overflowed.
    bytes4 internal constant PANIC = 0x4e487b71;

    struct Req {
        uint8 vault;
        uint256 requestId;
        bool isDeposit;
    }

    struct Vars {
        uint256[5] pricePerShare;
        D18 spokeSharePrice;
        D18 hubSharePrice;
        uint128[2] holdingValue;
        uint128[4] accountValue;
        bool[4] accountPositive;
        int256 queuedShares;
        uint64 nonce;
        uint256 supply;
    }

    Vars internal _before;
    Vars internal _after;
    OpType internal currentOperation;
    /// @dev The vault whose price this call's snapshots read, and the counter that turns it.
    uint8 internal sampledVault;
    uint256 internal sampleCounter;
    /// @dev Handlers that call handlers snapshot once, around the outermost.
    uint8 internal ghostDepth;
    /// @dev The claimable views' fingerprint before an operation that must leave them alone (`_claimsFingerprint`).
    bytes32 internal _claimsBefore;

    // Requests the fuzzer opened, in the order it opened them
    Req[] internal reqs;
    mapping(address vault => mapping(uint256 requestId => bool)) internal tracked;

    // Per-action reachability, read by the Foundry entrypoint's stats and non-vacuity test
    bytes32[] internal actionNames;
    mapping(bytes32 => uint256) internal ok;
    mapping(bytes32 => uint256) internal reverted;

    // Value flow per vault: what settlement made claimable and what claims paid out
    mapping(address vault => uint256) internal ghost_sharesOwed;
    mapping(address vault => uint256) internal ghost_assetsOwed;
    mapping(address vault => uint256) internal ghost_sharesClaimed;
    mapping(address vault => uint256) internal ghost_assetsClaimed;
    mapping(address vault => mapping(bool isDeposit => uint256)) internal ghost_requested;
    mapping(address vault => mapping(bool isDeposit => uint256)) internal ghost_fulfilledGross;
    mapping(address vault => mapping(bool isDeposit => uint256)) internal ghost_cancelledGross;

    // Instant-lane fees: what the recipient received in the actions the fee checks cover, what the policy quoted for
    // them, and what its balance moved by outside them
    uint256 internal ghost_feeReceived;
    uint256 internal ghost_feeQuoted;
    int256 internal ghost_feeUncovered;
    uint256 internal _feeBalanceBefore;
    uint256 internal _feeCoveredInCall;
    /// @dev Pool C's share supply at the start of the call, whether an instant action of the call went unchecked, and
    ///      whether the call settled or claimed, which no instant lane takes part in.
    uint256 internal _feePoolCSupplyBefore;
    bool internal _feeSkippedInCall;
    bool internal _feeNoInstantInCall;

    /// @dev Where a vault keeps its per-controller investment ledger, six `uint128` counters in three slots.
    uint256 internal constant INVESTMENTS_SLOT = 1;

    /// @dev USDC sent straight to pool A's escrow, which its holding never counts.
    uint256 internal ghost_donatedToEscrow;

    // Restrictions
    mapping(address => bool) internal frozen;
    /// @dev Vaults whose spoke manager role the pool withdrew: their claims may revert from then on.
    mapping(address => bool) internal vaultRevoked;
    /// @dev Vaults the pool unlinked: they refuse requests, flushes and callbacks, so a flow through one may revert.
    mapping(address => bool) internal vaultUnlinked;
    /// @dev Once the standard policy governs the pool, manager calls outside it wait for an authorization.
    bool internal hubPolicyInstalled;
    /// @dev The most open windows one controller held in a long-horizon vault at once.
    uint256 internal ghost_deepestHorizon;
    uint64 internal outsiderValidUntil;

    // Authorization
    bool internal auxIsManager;
    uint256 internal ghost_unauthorizedSuccess;
    uint256 internal ghost_privilegedOperationCount;
    address internal ghost_lastAuthorizedCaller;
    uint256 internal ghost_authorizationChanges;
    uint256 internal ghost_callsAfterRevocation;

    // Balance-sheet manager's own positions in pool A
    uint128 internal ghost_bsmReserved;
    uint128 internal ghost_bsmEscrowShares;

    // Share queue flushes, for nonce accounting
    uint256 internal ghost_shareQueueFlushes;

    /// @dev How many actions of the current handler call may still be judged on their siblings' ledgers. The check
    ///      hashes every sibling's ledgers around the action, so a handler that acts many times is judged on its first
    ///      few, and a rehearsal that must fit one call's gas is not judged at all.
    uint8 internal siblingBudget;
    uint8 internal constant SIBLING_CHECKS_PER_CALL = 2;

    modifier updateGhosts(OpType op) {
        if (ghostDepth++ == 0) {
            siblingBudget = SIBLING_CHECKS_PER_CALL;
            currentOperation = op;
            sampledVault = uint8(sampleCounter++ % vaults.length);
            _snapshot(_before);
            _feeBalanceBefore = usdc.balanceOf(FEE_RECIPIENT);
            _feeCoveredInCall = 0;
            _feePoolCSupplyBefore = shareC.totalSupply();
            _feeSkippedInCall = false;
            _feeNoInstantInCall = false;
            if (op == OpType.PRICE || op == OpType.TERMS) _claimsBefore = _claimsFingerprint(sampledVault);
        }
        _;
        if (--ghostDepth == 0) {
            _snapshot(_after);
            int256 feeGap = int256(usdc.balanceOf(FEE_RECIPIENT)) - int256(_feeBalanceBefore + _feeCoveredInCall);
            _checkFeeGap(feeGap);
            ghost_feeUncovered += feeGap;
            _checkDeltas();
            if (currentOperation == OpType.PRICE || currentOperation == OpType.TERMS) _checkClaimsFixed();
        }
    }

    /// @dev Implemented with the properties; must not revert.
    function _checkClaimsFixed() internal virtual;

    /// @dev What the fee recipient was paid in a call beyond what its checked actions account for. Implemented with
    ///      the fee properties; must not revert.
    function _checkFeeGap(int256 gap) internal virtual;

    /// @dev The checks that compare this call's snapshots. They run here, right after the handler, because the
    ///      fuzzer draws a property function only now and then and the snapshots hold the last handler's pair, so
    ///      a check left to a property function is judged on a small share of the calls. Implemented with the
    ///      properties; must not revert.
    function _checkDeltas() internal virtual;

    /// @dev What the call's properties read and nothing more, since a snapshot is paid twice per call: a repricing
    ///      is judged by the values it moved, every other operation by the prices it must leave alone. The vault
    ///      prices cost the most, so one vault is read per call, in turn, and only that slot is compared.
    function _snapshot(Vars storage v) internal {
        if (currentOperation == OpType.PRICE) {
            v.holdingValue[0] = holdings.value(poolA, scA, usdcId);
            v.holdingValue[1] = holdings.value(poolA, scA, cShareId);
            AccountId[4] memory accounts = _accounts();
            for (uint256 i; i < 4; i++) {
                (v.accountPositive[i], v.accountValue[i]) = accounting.accountValue(poolA, accounts[i]);
            }
        } else {
            try vaults[sampledVault].pricePerShare() returns (uint256 pps) {
                v.pricePerShare[sampledVault] = pps;
            } catch {
                v.pricePerShare[sampledVault] = 0;
            }
            try spokeRegistry.pricePoolPerShare(poolA, scA, false) returns (D18 p) {
                v.spokeSharePrice = p;
            } catch {
                v.spokeSharePrice = D18.wrap(0);
            }
            (v.hubSharePrice,) = shareClassManager.pricePoolPerShare(poolA, scA);
        }
        (uint128 delta, bool isPositive,, uint64 nonce) = snapshotQueue.queuedShares(poolA, scA);
        v.queuedShares = isPositive ? int256(uint256(delta)) : -int256(uint256(delta));
        v.nonce = nonce;
        v.supply = shareA.totalSupply();
    }

    //----------------------------------------------------------------------------------------------
    // Bookkeeping helpers
    //----------------------------------------------------------------------------------------------

    function _ok(bytes32 action) internal {
        if (ok[action] == 0 && reverted[action] == 0) actionNames.push(action);
        ok[action]++;
    }

    function _reverted(bytes32 action) internal {
        if (ok[action] == 0 && reverted[action] == 0) actionNames.push(action);
        reverted[action]++;
    }

    /// @dev The most a fold could still make claimable in one vault, computed from the buckets rather than the
    ///      views: every actor's settled pro-rata slices less their folded snapshots, cancellations included.
    function _unfoldedBound(uint8 v) internal view returns (uint256 shares, uint256 assets) {
        for (uint256 i; i < reqs.length; i++) {
            if (reqs[i].vault != v) continue;
            Bucket memory b = vaults[v].bucket(uint96(reqs[i].requestId));
            if (b.total == 0) continue;
            for (uint256 a; a < actors.length; a++) {
                Contribution memory c = vaults[v].contribution(uint96(reqs[i].requestId), actors[a]);
                if (c.amount == 0) continue;
                // Floored at zero: a snapshot above its slice is `property_foldedNeverExceedsSettled`'s to report
                uint256 net = _floorSub(MathLib.mulDiv(b.cancelledNet, c.amount, b.total), c.foldedCancelledNet);
                if (b.isDeposit) {
                    shares += _floorSub(MathLib.mulDiv(b.fulfilledShares, c.amount, b.total), c.foldedShares);
                    assets += net;
                } else {
                    assets += _floorSub(MathLib.mulDiv(b.fulfilledAssets, c.amount, b.total), c.foldedAssets);
                    shares += net;
                }
            }
        }
    }

    /// @dev Everything claimable across the actors in one vault, as the views report it.
    function _claimable(uint8 v) internal view returns (uint256 shares, uint256 assets) {
        for (uint256 a; a < actors.length; a++) {
            shares += vaults[v].claimableMint(actors[a]);
            assets += vaults[v].claimableWithdraw(actors[a]);
        }
    }

    /// @dev Fingerprint of every controller's claimable views in one pool A vault: the two ledger sides and the two
    ///      ERC-7540 request views. All four read the settlement state and never a price, so no repricing, fee,
    ///      policy or oracle change may move any of them. One vault per call (the sampled one), since the 60 views
    ///      over every vault cost about 380k gas and a snapshot is paid twice.
    function _claimsFingerprint(uint8 v) internal view returns (bytes32 h) {
        for (uint256 a; a < actors.length; a++) {
            h = keccak256(
                abi.encode(
                    h,
                    vaults[v].claimableMint(actors[a]),
                    vaults[v].claimableWithdraw(actors[a]),
                    vaults[v].claimableDepositRequest(0, actors[a]),
                    vaults[v].claimableRedeemRequest(0, actors[a])
                )
            );
        }
    }

    function _track(uint8 v, uint256 requestId, bool isDeposit) internal {
        if (tracked[address(vaults[v])][requestId]) return;
        if (reqs.length >= 32 && reqs.length % 16 == 0) _compactReqs();
        tracked[address(vaults[v])][requestId] = true;
        reqs.push(Req(v, requestId, isDeposit));
    }

    /// @dev Drops the requests nothing refers to any more, so the per-call properties, which walk `reqs`,
    ///      stay linear in the open requests rather than in every request ever made. Each property over
    ///      `reqs` reads zero for a dropped one, so dropping it changes no sum. A bucket a policy later
    ///      reuses is tracked again on its next request.
    function _compactReqs() internal {
        uint256 kept;
        for (uint256 i; i < reqs.length; i++) {
            Req memory r = reqs[i];
            if (_isSpent(r)) {
                tracked[address(vaults[r.vault])][r.requestId] = false;
                continue;
            }
            reqs[kept++] = r;
        }
        while (reqs.length > kept) {
            reqs.pop();
        }
    }

    /// @dev Nothing pending, queued, outstanding at the hub, reserved or held by any contributor.
    function _isSpent(Req memory r) internal view returns (bool) {
        IAsyncVault vault = vaults[r.vault];
        uint96 localId = uint96(r.requestId);
        Bucket memory b = vault.bucket(localId);
        if (BucketReference.outstanding(b) != 0 || b.queued != 0) return false;
        RequestId rid = RequestId.wrap(r.requestId);
        uint128 outstanding = r.isDeposit
            ? orderBook.depositOrders(poolA, scA, usdcId, rid)
            : orderBook.redeemOrders(poolA, scA, usdcId, rid);
        if (outstanding != 0) return false;
        for (uint256 a; a < actors.length; a++) {
            if (vault.contribution(localId, actors[a]).amount != 0) return false;
        }
        bytes32 reason = _depositReason(localId);
        return !r.isDeposit || _escrow(poolA).reservedBy(scA, address(vault), reason, address(usdc), 0) == 0;
    }

    /// @dev A pranked low-level call, so a handler can record a revert without a try/catch per selector.
    function _callAs(address who, address target, bytes memory data) internal returns (bool, bytes memory) {
        vm.prank(who);
        return target.call(data);
    }

    function _depositReason(uint96 localId) internal pure returns (bytes32) {
        return keccak256(abi.encode(REASON_DEPOSIT, localId));
    }

    /// @dev Whether a call by `actor` through `vault` is expected to go through: a lapsed member is refused by the
    ///      share hook, a retired vault by its router, and a vault without its role cannot pay.
    function _healthy(IAsyncVault vault, address actor) internal view returns (bool) {
        return _claimOpen(vault, actor) && !vaultUnlinked[address(vault)];
    }

    /// @dev Whether a claim must go through: a claim needs no link, so a vault unlinked to wind it down still pays
    ///      what was settled; only a member, and the role the vault pays through, are needed.
    function _claimOpen(IAsyncVault vault, address actor) internal view returns (bool) {
        (bool member,) = fullRestrictions.isMember(address(shareA), actor);
        return member && !vaultRevoked[address(vault)];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _vaultIndex(uint256 seed) internal view returns (uint8) {
        return uint8(seed % vaults.length);
    }

    /// @dev The first actor from `seed` holding pool A shares, or the seeded actor if none does.
    function _shareHolder(uint256 seed) internal view returns (address) {
        for (uint256 i; i < actors.length; i++) {
            address a = actors[(seed + i) % actors.length];
            if (shareA.balanceOf(a) != 0) return a;
        }
        return _actor(seed);
    }

    /// @dev The oracle's own verdict on pool A's USDC pair, the one every pool A vault prices with: pause, age and
    ///      skew. It does not look at the prices' values.
    function _oracleVerdict() internal view returns (bool valid) {
        (,, valid) = spokeOracle.prices(poolA, scA, usdcId);
    }

    /// @dev Whether the instant lane can price: the oracle vouches for the pair and neither price is zero, which
    ///      the vault refuses (`InvalidPrice`) because a zero price converts to nothing and clears every capacity check.
    function _oracleValid() internal view returns (bool valid) {
        D18 ppa;
        D18 pps;
        (ppa, pps, valid) = spokeOracle.prices(poolA, scA, usdcId);
        valid = valid && !ppa.isZero() && !pps.isZero();
    }

    function _larger(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /// @dev What the four pool A accounts can still take on either side before `int128.max`.
    function _accountRoom() internal view returns (uint256 room) {
        AccountId[4] memory accounts = _accounts();
        uint256 most;
        for (uint256 i; i < accounts.length; i++) {
            (uint128 totalDebit, uint128 totalCredit,,,) = accounting.accounts(poolA, accounts[i]);
            most = _larger(most, _larger(totalDebit, totalCredit));
        }
        room = uint256(uint128(type(int128).max)) - 1 - MathLib.min(most, uint256(uint128(type(int128).max)) - 1);
    }

    /// @dev The most assets that can still be credited: the whole supply, this credit included, must stay a quarter
    ///      of `uint128.max` and, valued at the hub's price, under a quarter of what the accounts can take, so that
    ///      `property_accountTotalsFitInt128` is tested against what the protocol does with large amounts and
    ///      not against what a manager could book by hand. The assets come back as pool C shares, which pool A
    ///      holds at a price of its own, so the USDC price counts only where it is above par: at a price of zero
    ///      the USDC is worth nothing but the shares are not.
    function _hugeAssets() internal view returns (uint256 cap) {
        uint256 ppa = MathLib.max(hub.pricePoolPerAsset(poolA, scA, usdcId).raw(), 1e18);
        uint256 byValue = _accountRoom() / 4 * 1e18 * ONE_ASSET / (ppa * ONE_SHARE);
        uint256 total = byValue < type(uint128).max / 4 ? byValue : type(uint128).max / 4;
        uint256 supply = usdc.totalSupply();
        cap = total > supply ? total - supply : 0;
    }

    /// @dev Shares held by system contracts must be zero, so they belong in no holder sum.
    function _shareHolders() internal view returns (address[] memory holders) {
        holders = new address[](actors.length + 4);
        for (uint256 i; i < actors.length; i++) {
            holders[i] = actors[i];
        }
        holders[actors.length] = address(_escrow(poolA));
        holders[actors.length + 1] = BSM;
        holders[actors.length + 2] = OUTSIDER;
        holders[actors.length + 3] = AUX_MANAGER;
    }

    /// @dev `a - b` floored at zero, for ghost math that must not revert.
    function _floorSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function _signed(uint128 delta, bool isPositive) internal pure returns (int256) {
        return isPositive ? int256(uint256(delta)) : -int256(uint256(delta));
    }

    function _poolAssets() internal view returns (AssetId[3] memory) {
        return [usdcId, cShareId, basinLiabilityId];
    }

    function _assetAddress(AssetId assetId) internal view returns (address) {
        return assetId.raw() == usdcId.raw() ? address(usdc) : address(shareC);
    }

    function _scOf(PoolId poolId) internal view returns (ShareClassId) {
        return poolId.raw() == poolA.raw() ? scA : poolId.raw() == poolB.raw() ? scB : scC;
    }
}
