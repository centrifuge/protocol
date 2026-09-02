// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAdapter} from "../../../../src/core/messaging/interfaces/IAdapter.sol";
import {MAX_ADAPTER_COUNT} from "../../../../src/core/messaging/interfaces/IMultiAdapter.sol";

import {SimpleAdapter} from "../mocks/SimpleAdapter.sol";

import {Asserts} from "@chimera/Asserts.sol";
import {BeforeAfter} from "../BeforeAfter.sol";

abstract contract MultiAdapterTargets is BeforeAfter, Asserts {
    modifier validPayload(bytes calldata payload) {
        require(payload.length > 0 && payload.length <= 200, "invalid payload");
        _;
    }

    // ─── Positive delivery targets ────────────────────────────────────────────

    /// @dev Deliver via one active adapter. Ghosts key on the UNWRAPPED hash while the payload is
    ///      wrapped with the active session id; baselines precede the effect, delivery recorded on success.
    function multiAdapter_deliver(uint8 adapterIdx, bytes calldata payload) public validPayload(payload) {
        IAdapter[] memory list = _activeList();
        precondition(list.length > 0); // active session may be blocked
        uint256 idx = between(uint256(adapterIdx), 0, list.length - 1);
        bytes memory p = _bucket(payload);

        _captureBaselines(REMOTE_CENTRIFUGE_ID, p);
        SimpleAdapter(address(list[idx])).deliver(_wrap(p));
        _recordSuccessfulDelivery(REMOTE_CENTRIFUGE_ID, p);
    }

    /// @dev Deliver via all three adapters; those dropped by a count<3 reconfigure naturally revert
    ///      InvalidAdapter and the fuzzer prunes it.
    function multiAdapter_deliverAll(bytes calldata payload) public validPayload(payload) {
        bytes memory p = _bucket(payload);
        _captureBaselines(REMOTE_CENTRIFUGE_ID, p);
        bytes memory wrapped = _wrap(p);

        adapter0.deliver(wrapped);
        _recordSuccessfulDelivery(REMOTE_CENTRIFUGE_ID, p);

        adapter1.deliver(wrapped);
        _recordSuccessfulDelivery(REMOTE_CENTRIFUGE_ID, p);

        adapter2.deliver(wrapped);
        _recordSuccessfulDelivery(REMOTE_CENTRIFUGE_ID, p);
    }

    /// @dev Deliver the same payload via two distinct adapters, guaranteeing an execution at threshold=2.
    function multiAdapter_deliverToThreshold(bytes calldata payload) public validPayload(payload) {
        bytes memory p = _bucket(payload);
        _captureBaselines(REMOTE_CENTRIFUGE_ID, p);
        bytes memory wrapped = _wrap(p);

        adapter0.deliver(wrapped);
        _recordSuccessfulDelivery(REMOTE_CENTRIFUGE_ID, p);

        adapter1.deliver(wrapped);
        _recordSuccessfulDelivery(REMOTE_CENTRIFUGE_ID, p);
    }

    // ─── Reconfiguration targets ──────────────────────────────────────────────

    /// @dev Reconfigure the adapter set; clears per-session ghosts (cumulative ghosts persist).
    function multiAdapter_reconfigure(uint8 adapterCountSeed, uint8 thresholdSeed) public {
        uint8 count = uint8(between(uint256(adapterCountSeed), 1, ADAPTER_COUNT));
        uint8 threshold_ = uint8(between(uint256(thresholdSeed), 1, count));

        IAdapter[] memory addrs = _buildAdapterArray(count);

        uint16 sidBefore = multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);

        // setAdapters fails closed unless targetSessionId equals the pool's next session id, so a stale
        // or reordered configuration cannot desync the two endpoints.
        uint16 target = multiAdapter.nextActiveSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        t(target == sidBefore + 1, "session-id: nextActiveSessionId != activeSessionId + 1");

        multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, threshold_, target);

        // Advances by exactly 1 to the target; no wrap, at type(uint16).max it panics and sessions end.
        uint16 sidAfter = multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        t(sidAfter == target, "session-id: did not install targetSessionId");

        _clearTrackedDeliveries();
    }

    // ─── Proof-adapter split: vote() / execute() targets ─────────────────────

    /// @dev V1 – vote() records a vote but must never execute or fail-record it; a vote counts as a delivery.
    function multiAdapter_vote(uint8 adapterIdx, bytes calldata payload) public validPayload(payload) {
        IAdapter[] memory list = _activeList();
        precondition(list.length > 0);
        uint256 idx = between(uint256(adapterIdx), 0, list.length - 1);
        bytes memory p = _bucket(payload);

        bytes32 hash = keccak256(p);
        uint256 ccBefore = countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, hash);
        uint256 failedBefore = gateway.failedMessages(REMOTE_CENTRIFUGE_ID, hash);

        _captureBaselines(REMOTE_CENTRIFUGE_ID, p);
        SimpleAdapter(address(list[idx])).deliverVote(_wrap(p));
        _recordSuccessfulDelivery(REMOTE_CENTRIFUGE_ID, p);

        eq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, hash), ccBefore, "V1: vote() executed the message");
        eq(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, hash), failedBefore, "V1: vote() reached the gateway");
    }

    /// @dev Consume quorum votes from vote()/handle(). Below threshold it naturally reverts NotEnoughVotes.
    function multiAdapter_execute(uint8 adapterIdx, bytes calldata payload) public validPayload(payload) {
        IAdapter[] memory list = _activeList();
        precondition(list.length > 0);
        uint256 idx = between(uint256(adapterIdx), 0, list.length - 1);
        bytes memory p = _bucket(payload);

        _captureBaselines(REMOTE_CENTRIFUGE_ID, p);
        SimpleAdapter(address(list[idx])).deliverExecute(_wrap(p));
        // execute() consumes prior votes: credit the execution, not a delivery.
        _recordQuorumEvent(REMOTE_CENTRIFUGE_ID, keccak256(p));
    }

    /// @dev V2 – execute() below the vote threshold must revert with NotEnoughVotes.
    function multiAdapter_execute_belowThreshold_mustRevert(uint8 adapterIdxSeed, bytes calldata payload)
        public
        validPayload(payload)
    {
        IAdapter[] memory list = _activeList();
        precondition(list.length > 0);
        uint256 idx = between(uint256(adapterIdxSeed), 0, list.length - 1);

        bytes memory wrapped = _wrap(_bucket(payload));
        uint8 q = multiAdapter.quorum(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        uint8 thr = multiAdapter.threshold(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        int16[MAX_ADAPTER_COUNT] memory v = multiAdapter.votes(REMOTE_CENTRIFUGE_ID, _voteKey(wrapped));
        uint256 positives;
        for (uint8 j; j < q; j++) {
            if (v[j] > 0) positives++;
        }
        precondition(positives < thr); // at/above threshold execute() would legitimately succeed

        try SimpleAdapter(address(list[idx])).deliverExecute(wrapped) {
            t(false, "V2: execute succeeded below threshold");
        } catch (bytes memory err) {
            t(checkError(err, "NotEnoughVotes()"), "V2: wrong revert (expected NotEnoughVotes)");
        }
        require(false);
    }

    // ─── Pool-manager targets (updateManager + manager-driven handle) ────────

    /// @dev Toggle the pool-manager role for the non-ward `managerActor`. An enabled manager can submit
    ///      for any configured adapter and reach quorum alone: fully trusted, so no property restricts it.
    function multiAdapter_updateManager(bool canManage) public {
        multiAdapter.updateManager(GLOBAL_POOL, address(managerActor), canManage);
        t(
            multiAdapter.manager(GLOBAL_POOL, address(managerActor)) == canManage,
            "updateManager: manager getter does not reflect update"
        );
    }

    /// @dev Manager submits on behalf of a configured adapter (3-arg handle), equal to that adapter's vote.
    function multiAdapter_managerDeliver(uint8 adapterIdx, bytes calldata payload) public validPayload(payload) {
        precondition(multiAdapter.manager(GLOBAL_POOL, address(managerActor)));
        IAdapter[] memory list = _activeList();
        precondition(list.length > 0);
        uint256 idx = between(uint256(adapterIdx), 0, list.length - 1);
        bytes memory p = _bucket(payload);

        _captureBaselines(REMOTE_CENTRIFUGE_ID, p);
        managerActor.handleAs(REMOTE_CENTRIFUGE_ID, _wrap(p), list[idx]);
        _recordSuccessfulDelivery(REMOTE_CENTRIFUGE_ID, p);
    }

    /// @dev MA1 – without the manager role, submitting for an adapter must revert NotAuthorized, which
    ///      `_resolve` checks before adapter validity.
    function multiAdapter_managerHandle_notManager_mustRevert(bytes calldata payload) public validPayload(payload) {
        precondition(!multiAdapter.manager(GLOBAL_POOL, address(managerActor)));

        try managerActor.handleAs(REMOTE_CENTRIFUGE_ID, _wrap(payload), IAdapter(address(adapter0))) {
            t(false, "MA1: non-manager submitted on behalf of an adapter");
        } catch (bytes memory err) {
            t(checkError(err, "NotAuthorized()"), "MA1: wrong revert (expected NotAuthorized)");
        }
        require(false);
    }

    // ─── Session blocking targets (blockSession / unblockSession) ────────────

    function multiAdapter_blockSession(uint8 sessionSeed, bytes calldata payload) public validPayload(payload) {
        uint16 active = multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        precondition(active > 0);
        uint16 sid = uint16(between(uint256(sessionSeed), 1, active));
        // Already-blocked sessions have their config stashed, so blockSession reverts SessionNotConfigured.
        precondition(!multiAdapter.blockedSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid));

        multiAdapter.blockSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid);

        t(
            multiAdapter.blockedSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid),
            "blockSession: session not reported blocked"
        );

        if (sid == active) {
            t(
                multiAdapter.quorum(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL) == 0,
                "blockSession: active adapter set not cleared"
            );
        }

        // A stale delivery carrying the blocked sessionId must be rejected: the replay kill-switch.
        try adapter0.deliver(abi.encodePacked(sid, payload)) {
            t(false, "blockSession: delivery on blocked session succeeded");
        } catch (bytes memory err) {
            t(checkError(err, "InvalidAdapter()"), "blockSession: wrong revert (expected InvalidAdapter)");
        }
    }

    function multiAdapter_unblockSession(uint8 sessionSeed) public {
        uint16 active = multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        precondition(active > 0);
        uint16 sid = uint16(between(uint256(sessionSeed), 1, active));
        precondition(multiAdapter.blockedSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid));

        multiAdapter.unblockSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid);

        t(
            !multiAdapter.blockedSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid),
            "unblockSession: session still reported blocked"
        );

        if (sid == active) {
            // The session id never moves backwards, so sid == active means it was active when blocked.
            t(_activeList().length > 0, "unblockSession: active adapter set not restored");
        }
    }

    /// @dev B1 – blockSession on a session with no configuration must revert SessionNotConfigured.
    function multiAdapter_blockSession_unconfigured_mustRevert(uint8 sessionSeed) public {
        uint16 active = multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        uint16 sid = uint16(between(uint256(sessionSeed), uint256(active) + 1, uint256(active) + 100));

        try multiAdapter.blockSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid) {
            t(false, "B1: blockSession succeeded on unconfigured session");
        } catch (bytes memory err) {
            t(checkError(err, "SessionNotConfigured()"), "B1: wrong revert (expected SessionNotConfigured)");
        }
        require(false);
    }

    /// @dev B2 – unblockSession on a session that is not blocked must revert SessionNotBlocked.
    function multiAdapter_unblockSession_notBlocked_mustRevert(uint8 sessionSeed) public {
        uint16 sid = uint16(between(uint256(sessionSeed), 0, type(uint16).max));
        precondition(!multiAdapter.blockedSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid));

        try multiAdapter.unblockSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid) {
            t(false, "B2: unblockSession succeeded on non-blocked session");
        } catch (bytes memory err) {
            t(checkError(err, "SessionNotBlocked()"), "B2: wrong revert (expected SessionNotBlocked)");
        }
        require(false);
    }

    // ─── Negative targets — split per error mode (one branch per handler) ─────
    // Each negative target ends with `require(false)`: successful runs count as reverted, so shrunk
    // traces stay short.

    /// @dev M6.a – setAdapters with too many adapters must revert with ExceedsMax.
    function multiAdapter_setAdapters_exceedsMax_mustRevert() public {
        IAdapter[] memory addrs = new IAdapter[](MAX_ADAPTER_COUNT + 1);
        for (uint8 i; i < MAX_ADAPTER_COUNT + 1; i++) {
            addrs[i] = IAdapter(address(adapter0));
        }
        try multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, 1, _nextSession()) {
            t(false, "M6.a: setAdapters with count > MAX_ADAPTER_COUNT must revert");
        } catch (bytes memory err) {
            t(checkError(err, "ExceedsMax()"), "M6.a: wrong revert (expected ExceedsMax)");
        }
        require(false);
    }

    /// @dev M6.b – setAdapters with threshold > count must revert with ThresholdHigherThanQuorum.
    function multiAdapter_setAdapters_thresholdHigh_mustRevert(uint8 adapterCountSeed) public {
        uint8 count = uint8(between(uint256(adapterCountSeed), 1, ADAPTER_COUNT));
        uint8 threshold_ = count + 1;
        IAdapter[] memory addrs = _buildAdapterArray(count);
        try multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, threshold_, _nextSession()) {
            t(false, "M6.b: setAdapters with threshold > quorum must revert");
        } catch (bytes memory err) {
            t(checkError(err, "ThresholdHigherThanQuorum()"), "M6.b: wrong revert (expected ThresholdHigherThanQuorum)");
        }
        require(false);
    }

    /// @dev M6.d – duplicate adapters must revert NoDuplicatesAllowed, which `_installSession` raises
    ///      AFTER the targetSessionId check, so the target must pass the correct next session id.
    function multiAdapter_setAdapters_duplicates_mustRevert() public {
        IAdapter[] memory addrs = new IAdapter[](2);
        addrs[0] = IAdapter(address(adapter0));
        addrs[1] = IAdapter(address(adapter0));
        try multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, 1, _nextSession()) {
            t(false, "M6.d: setAdapters with duplicate adapters must revert");
        } catch (bytes memory err) {
            t(checkError(err, "NoDuplicatesAllowed()"), "M6.d: wrong revert (expected NoDuplicatesAllowed)");
        }
        require(false);
    }

    /// @dev M6.e – threshold 0 over a non-empty set must revert ZeroThreshold: it would let any single
    ///      adapter forward without consensus. An EMPTY set with threshold 0 is the legal disable path.
    function multiAdapter_setAdapters_zeroThreshold_mustRevert(uint8 adapterCountSeed) public {
        uint8 count = uint8(between(uint256(adapterCountSeed), 1, ADAPTER_COUNT));
        IAdapter[] memory addrs = _buildAdapterArray(count);
        try multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, 0, _nextSession()) {
            t(false, "M6.e: setAdapters with threshold 0 over a non-empty set must revert");
        } catch (bytes memory err) {
            t(checkError(err, "ZeroThreshold()"), "M6.e: wrong revert (expected ZeroThreshold)");
        }
        require(false);
    }

    /// @dev M6.f – a targetSessionId other than the pool's next id must revert UnexpectedSessionId: the
    ///      hub derives one id for both endpoints, so a stale or reordered config fails closed.
    function multiAdapter_setAdapters_wrongSession_mustRevert(uint8 adapterCountSeed, uint16 sessionSeed) public {
        uint8 count = uint8(between(uint256(adapterCountSeed), 1, ADAPTER_COUNT));
        IAdapter[] memory addrs = _buildAdapterArray(count);

        uint16 next = _nextSession();
        // Span [0, next + 2] so stale, exact and leap-ahead are reachable, minus the value that succeeds.
        uint16 wrongTarget = uint16(between(uint256(sessionSeed), 0, uint256(next) + 2));
        precondition(wrongTarget != next);

        try multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, 1, wrongTarget) {
            t(false, "M6.f: setAdapters with a mismatched targetSessionId must revert");
        } catch (bytes memory err) {
            t(checkError(err, "UnexpectedSessionId()"), "M6.f: wrong revert (expected UnexpectedSessionId)");
        }
        require(false);
    }

    // ─── Cross-session negative target: deactivated adapter must reject ──────

    /// @dev Adapters NOT in the active session's set must reject deliver with InvalidAdapter. Membership
    ///      is read from the LIVE active list; reconfigures install non-prefix sets like [adapter1].
    function multiAdapter_oldAdapter_mustRevert(uint8 adapterIdxSeed, bytes calldata payload)
        public
        validPayload(payload)
    {
        uint8 idx = uint8(between(uint256(adapterIdxSeed), 0, ADAPTER_COUNT - 1)); // 0..2
        SimpleAdapter targetAdapter = idx == 0 ? adapter0 : (idx == 1 ? adapter1 : adapter2);
        precondition(!_isActive(address(targetAdapter))); // active adapter would deliver fine

        try targetAdapter.deliver(_wrap(payload)) {
            t(false, "old-adapter: inactive adapter delivered successfully");
        } catch (bytes memory err) {
            t(checkError(err, "InvalidAdapter()"), "old-adapter: wrong revert (expected InvalidAdapter)");
        }
        require(false);
    }

    // ─── Alex-1 cross-session replay attack target ────────────────────────────

    /// @dev Cross-session replay regression: votes are keyed by the session-prefixed payload, so bytes
    ///      replayed after a reconfigure count under the OLD session's threshold (>= 2) and cannot
    ///      re-execute. Mutates state deliberately, so no trailing `require(false)`.
    function multiAdapter_alex1_replay_must_not_execute(uint8 keepIdxSeed, bytes calldata payload)
        public
        validPayload(payload)
    {
        IAdapter[] memory list = _activeList();
        precondition(list.length > 0); // active session may be blocked
        bytes memory p = _bucket(payload);
        bytes32 hash = keccak256(p);
        uint256 keepIdx = between(uint256(keepIdxSeed), 0, list.length - 1);

        // Step 1: reach threshold via the current configuration using distinct adapters.
        uint8 thr = multiAdapter.threshold(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        precondition(thr >= 2); // threshold=1 duplicate re-execution is by design, not the replay bug

        // The OLD session's wrapped bytes: what a stale commandId would still hold after step 2.
        bytes memory staleWrapped = _wrap(p);

        // Leftover votes on these bytes could combine with the replay into a LEGITIMATE second
        // execution (two distinct adapters), which is not the replay bug: require a clean slate.
        {
            int16[MAX_ADAPTER_COUNT] memory v = multiAdapter.votes(REMOTE_CENTRIFUGE_ID, _voteKey(staleWrapped));
            for (uint8 i; i < MAX_ADAPTER_COUNT; i++) {
                precondition(v[i] == 0);
            }
        }

        for (uint256 i; i < thr; i++) {
            SimpleAdapter voter = SimpleAdapter(address(list[(keepIdx + i) % list.length]));
            _captureBaselines(REMOTE_CENTRIFUGE_ID, p);
            voter.deliver(staleWrapped);
            _recordSuccessfulDelivery(REMOTE_CENTRIFUGE_ID, p);
        }

        uint256 cc1 = countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, hash);
        if (cc1 == 0) return; // didn't execute (e.g., processor forced-fail) — nothing to replay

        // Step 2: reconfigure to a single-adapter set that keeps the original delivering adapter.
        SimpleAdapter keep = SimpleAdapter(address(list[keepIdx]));
        IAdapter[] memory only = new IAdapter[](1);
        only[0] = IAdapter(address(keep));

        uint16 sidBefore = multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, only, 1, sidBefore + 1);
        uint16 sidAfter = multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        t(sidAfter == sidBefore + 1, "session-id: did not advance by exactly 1");

        _clearTrackedDeliveries();

        // Step 3: same adapter replays the STALE bytes; one vote under the old session's threshold (>= 2).
        _captureBaselines(REMOTE_CENTRIFUGE_ID, p);
        keep.deliver(staleWrapped);
        _recordSuccessfulDelivery(REMOTE_CENTRIFUGE_ID, p);

        uint256 cc2 = countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, hash);

        eq(cc2, cc1, "alex1: message replayed across sessions (callCount increased)");
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// @dev The only targetSessionId `setAdapters` accepts, read fresh so a reconfigure cannot desync it.
    function _nextSession() internal view returns (uint16) {
        return multiAdapter.nextActiveSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
    }

    function _buildAdapterArray(uint8 count) internal view returns (IAdapter[] memory addrs) {
        addrs = new IAdapter[](count);
        addrs[0] = IAdapter(address(adapter0));
        if (count > 1) addrs[1] = IAdapter(address(adapter1));
        if (count > 2) addrs[2] = IAdapter(address(adapter2));
    }
}
