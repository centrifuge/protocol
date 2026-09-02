// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Setup} from "./Setup.sol";

import {Utils} from "@recon/Utils.sol";

struct TrackedPair {
    uint16 centrifugeId;
    bytes32 payloadHash;
}

/// @dev `Utils` is inherited here, not per-target, so `checkError` is available suite-wide.
abstract contract BeforeAfter is Setup, Utils {
    // ─── Per-session ghosts (reset on reconfigure) ────────────────────────────
    // Used by M1, M4, G2, G4: bounds within the current session only.

    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => uint256)) internal ghost_deliveries;

    TrackedPair[] internal ghost_tracked;
    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => bool)) internal ghost_isTracked;

    /// @dev `countingProcessor.callCount` before the session's first delivery; properties read the delta.
    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => uint256)) internal ghost_baselineCallCount;

    /// @dev Same idea for `gateway.failedMessages`.
    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => uint256)) internal ghost_baselineFailedMessages;

    /// @dev Vote-tally key `keccak256(routedPoolId ++ sessionId ++ payload)`, captured at first track.
    ///      `multiAdapter.votes` is keyed by this; callCount / failedMessages by the unwrapped hash.
    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => bytes32)) internal ghost_voteKey;

    // ─── Cumulative (cross-session) ghosts (NEVER reset) ──────────────────────
    // Used by M1c (weighted-execution ledger), callCount monotonicity, alex1 replay detection.

    /// @dev Total deliveries across ALL sessions per (cId, hash).
    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => uint256)) internal ghost_cumDeliveries;

    /// @dev Sum over observed executions of (delta_callCount * threshold_at_observation); bounded by M1c.
    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => uint256)) internal ghost_cumExecutionsWeighted;

    /// @dev Last observed `callCount(cId, hash)`: detects new executions and backs the monotonicity property.
    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => uint256)) internal ghost_cumLastSeenCallCount;

    /// @dev Last observed `failedMessages(cId, hash)`, so `_recordQuorumEvent` also detects failed executions.
    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => uint256)) internal ghost_cumLastSeenFailedMessages;

    /// @dev Cross-session tracked pairs; entries are NEVER removed, so cumulative properties see every pair.
    TrackedPair[] internal ghost_cumTracked;
    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => bool)) internal ghost_isCumTracked;

    // Deliberately NO ghost mirroring the active adapter set: targets read the live `_activeList()` /
    // `_isActive()`. A "first N of adapter0..2" count ghost misreads non-prefix sets like [adapter1].

    // ─── Delivery accounting helpers ──────────────────────────────────────────

    /// @dev PRE-deliver hook: baseline before the on-chain effect, so this delivery's executions show as delta.
    function _captureBaselines(uint16 centrifugeId, bytes memory payload) internal {
        bytes32 payloadHash = keccak256(payload);

        if (!ghost_isTracked[centrifugeId][payloadHash]) {
            ghost_isTracked[centrifugeId][payloadHash] = true;
            ghost_tracked.push(TrackedPair(centrifugeId, payloadHash));
            ghost_baselineCallCount[centrifugeId][payloadHash] = countingProcessor.callCount(centrifugeId, payloadHash);
            ghost_baselineFailedMessages[centrifugeId][payloadHash] = gateway.failedMessages(centrifugeId, payloadHash);
            ghost_voteKey[centrifugeId][payloadHash] = _voteKey(_wrap(payload));
        }

        if (!ghost_isCumTracked[centrifugeId][payloadHash]) {
            ghost_isCumTracked[centrifugeId][payloadHash] = true;
            ghost_cumTracked.push(TrackedPair(centrifugeId, payloadHash));
            ghost_cumLastSeenCallCount[centrifugeId][payloadHash] =
                countingProcessor.callCount(centrifugeId, payloadHash);
            ghost_cumLastSeenFailedMessages[centrifugeId][payloadHash] =
                gateway.failedMessages(centrifugeId, payloadHash);
        }
    }

    /// @dev POST-deliver hook, success path ONLY: callers must skip it on revert so reverts don't pollute ghosts.
    ///      A delivery is anything that casts one vote: handle() or vote().
    function _recordSuccessfulDelivery(uint16 centrifugeId, bytes memory payload) internal {
        bytes32 payloadHash = keccak256(payload);

        ghost_deliveries[centrifugeId][payloadHash]++;
        ghost_cumDeliveries[centrifugeId][payloadHash]++;

        _recordQuorumEvent(centrifugeId, payloadHash);
    }

    /// @dev Credit every QUORUM EVENT caused by the just-completed handler to the cumulative weighted ledger at
    ///      the current threshold. A quorum event consumes a full `threshold` of fresh votes: a successful
    ///      execution (callCount up) or a failed one (failedMessages up). retry / clearFailedMessage cast no fresh
    ///      votes, so they call `_syncCumCounters` and credit nothing; execute() is credited without a delivery.
    function _recordQuorumEvent(uint16 centrifugeId, bytes32 payloadHash) internal {
        uint256 currentCallCount = countingProcessor.callCount(centrifugeId, payloadHash);
        uint256 currentFailed = gateway.failedMessages(centrifugeId, payloadHash);

        uint256 lastCallCount = ghost_cumLastSeenCallCount[centrifugeId][payloadHash];
        uint256 lastFailed = ghost_cumLastSeenFailedMessages[centrifugeId][payloadHash];

        uint256 execEvents = currentCallCount > lastCallCount ? currentCallCount - lastCallCount : 0;
        uint256 failEvents = currentFailed > lastFailed ? currentFailed - lastFailed : 0;
        uint256 events = execEvents + failEvents;

        if (events > 0) {
            uint256 thresholdNow = uint256(multiAdapter.threshold(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL));
            ghost_cumExecutionsWeighted[centrifugeId][payloadHash] += events * thresholdNow;
        }

        ghost_cumLastSeenCallCount[centrifugeId][payloadHash] = currentCallCount;
        ghost_cumLastSeenFailedMessages[centrifugeId][payloadHash] = currentFailed;
    }

    /// @dev Advance the last-seen counters WITHOUT crediting the weighted ledger: retry / clearFailedMessage cast
    ///      no fresh votes, so their movements must be absorbed here or a later quorum event is mis-detected.
    function _syncCumCounters(uint16 centrifugeId, bytes32 payloadHash) internal {
        ghost_cumLastSeenCallCount[centrifugeId][payloadHash] = countingProcessor.callCount(centrifugeId, payloadHash);
        ghost_cumLastSeenFailedMessages[centrifugeId][payloadHash] = gateway.failedMessages(centrifugeId, payloadHash);
    }

    /// @dev Reset PER-SESSION ghosts only, from `multiAdapter_reconfigure`, so M1/M4/G2/G4 scope to one session.
    function _clearTrackedDeliveries() internal {
        uint256 n = ghost_tracked.length;
        for (uint256 i; i < n; i++) {
            TrackedPair memory p = ghost_tracked[i];
            delete ghost_deliveries[p.centrifugeId][p.payloadHash];
            delete ghost_isTracked[p.centrifugeId][p.payloadHash];
            delete ghost_baselineCallCount[p.centrifugeId][p.payloadHash];
            delete ghost_baselineFailedMessages[p.centrifugeId][p.payloadHash];
            delete ghost_voteKey[p.centrifugeId][p.payloadHash];
        }
        delete ghost_tracked;
    }
}
