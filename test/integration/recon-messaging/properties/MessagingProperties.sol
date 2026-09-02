// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAdapter} from "../../../../src/core/messaging/interfaces/IAdapter.sol";
import {MAX_ADAPTER_COUNT} from "../../../../src/core/messaging/interfaces/IMultiAdapter.sol";

import {Asserts} from "@chimera/Asserts.sol";
import {BeforeAfter, TrackedPair} from "../BeforeAfter.sol";

abstract contract MessagingProperties is BeforeAfter, Asserts {
    // ─── MultiAdapter invariants ──────────────────────────────────────────────

    /// @dev M1 – Per session, per (centrifugeId, payloadHash): callCount * threshold <= deliveries.
    ///      Counted from the first-delivery baseline; `_clearTrackedDeliveries` resets the set on reconfigure.
    function property_M1_threshold_respected() public {
        uint256 threshold_ = uint256(multiAdapter.threshold(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL));
        uint256 n = ghost_tracked.length;

        for (uint256 i; i < n; i++) {
            TrackedPair memory p = ghost_tracked[i];

            uint256 deliveries = ghost_deliveries[p.centrifugeId][p.payloadHash];
            uint256 calls = countingProcessor.callCount(p.centrifugeId, p.payloadHash)
                - ghost_baselineCallCount[p.centrifugeId][p.payloadHash];

            lte(calls * threshold_, deliveries, "M1: callCount * threshold > deliveries");
        }
    }

    /// @dev M2 – Every index in the active set [0, quorum) is non-zero and pairwise distinct.
    function property_M2_adapter_set_integrity() public {
        uint8 q = multiAdapter.quorum(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        if (q == 0) return;

        uint16 sid = multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        IAdapter[] memory active = new IAdapter[](q);
        for (uint8 i; i < q; i++) {
            active[i] = multiAdapter.adapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid, i);
            t(address(active[i]) != address(0), "M2: adapter at active index is zero");
        }

        for (uint8 i; i < q; i++) {
            for (uint8 j = i + 1; j < q; j++) {
                t(active[i] != active[j], "M2: duplicate adapters in active set");
            }
        }
    }

    /// @dev M3 – `1 <= threshold <= quorum` whenever a set is active, covering the write paths M6.e does not
    ///      (`_installSession`, `unblockSession` restore). Vacuous while no set is active: quorum reads 0.
    function property_M3_threshold_leq_quorum() public {
        uint8 q = multiAdapter.quorum(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        uint8 thr = multiAdapter.threshold(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);

        lte(uint256(thr), uint256(q), "M3: threshold > quorum");
        if (q >= 1) gte(uint256(thr), 1, "M3: zero threshold over a non-empty adapter set");
    }

    /// @dev M4 – Per session: sumPositive(votes) <= deliveries. Votes live under `ghost_voteKey` =
    ///      `keccak256(routedPoolId ++ sessionId ++ payload)`; a wrong key reads all-zero and passes vacuously.
    function property_M4_vote_sum_bounded() public {
        uint256 n = ghost_tracked.length;
        uint8 q = multiAdapter.quorum(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);

        for (uint256 i; i < n; i++) {
            TrackedPair memory p = ghost_tracked[i];

            bytes32 voteKey = ghost_voteKey[p.centrifugeId][p.payloadHash];
            int16[MAX_ADAPTER_COUNT] memory v = multiAdapter.votes(p.centrifugeId, voteKey);
            uint256 positiveSum;
            for (uint8 j; j < q; j++) {
                if (v[j] > 0) positiveSum += uint16(v[j]);
            }

            uint256 deliveries = ghost_deliveries[p.centrifugeId][p.payloadHash];
            lte(positiveSum, deliveries, "M4: positive vote sum > deliveries");
        }
    }

    // ─── Gateway invariants ───────────────────────────────────────────────────

    /// @dev G1 – isBatching is false between transactions. Transient storage resets per tx: near-tautological.
    function property_G1_isBatching_false() public {
        t(!gateway.isBatching(), "G1: isBatching is true between transactions");
    }

    /// @dev G2 – Per session: (callCount + failedMessages) * threshold <= deliveries. One gateway.handle() per
    ///      threshold reach; retry() moves a count from failedMessages to callCount, preserving the sum.
    function property_G2_execution_conservation() public {
        uint256 threshold_ = uint256(multiAdapter.threshold(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL));
        uint256 n = ghost_tracked.length;

        for (uint256 i; i < n; i++) {
            TrackedPair memory p = ghost_tracked[i];

            uint256 deliveries = ghost_deliveries[p.centrifugeId][p.payloadHash];
            uint256 calls = countingProcessor.callCount(p.centrifugeId, p.payloadHash)
                - ghost_baselineCallCount[p.centrifugeId][p.payloadHash];
            // Saturating: retry/clear can push failedMessages below the baseline captured at first track.
            uint256 failedNow = gateway.failedMessages(p.centrifugeId, p.payloadHash);
            uint256 failedBase = ghost_baselineFailedMessages[p.centrifugeId][p.payloadHash];
            uint256 failed = failedNow > failedBase ? failedNow - failedBase : 0;

            lte((calls + failed) * threshold_, deliveries, "G2: (callCount + failedMessages) * threshold > deliveries");
        }
    }

    /// @dev G3 – retry reverts for a message that has not failed; enforced in `gateway_retry_nonFailed_mustRevert`.

    /// @dev G4 – Per session: failedMessages <= deliveries, since `_safeProcess` fails at most once per handle.
    function property_G4_failed_messages_bounded() public {
        uint256 n = ghost_tracked.length;
        for (uint256 i; i < n; i++) {
            TrackedPair memory p = ghost_tracked[i];

            // Saturating diff: see G2 for why failedMessages can drop below its baseline.
            uint256 failedNow = gateway.failedMessages(p.centrifugeId, p.payloadHash);
            uint256 failedBase = ghost_baselineFailedMessages[p.centrifugeId][p.payloadHash];
            uint256 failed = failedNow > failedBase ? failedNow - failedBase : 0;

            uint256 deliveries = ghost_deliveries[p.centrifugeId][p.payloadHash];
            lte(failed, deliveries, "G4: failedMessages > deliveries");
        }
    }

    /// @dev G5 / G5b / G6 – pause and session-block enforcement, in `gateway_handle_whenPaused_mustRevert`,
    ///      `gateway_retry_whenPaused_mustRevert` and `gateway_send_whenBlocked_mustRevert` (G6: EmptyAdapterSet).

    // ─── Cross-session (cumulative) invariants ───────────────────────────────

    /// @dev M1c – Across ALL sessions: sum(callCountDelta * thresholdAtObservation) <= cumulativeDeliveries.
    ///      Arithmetic only; structural replay is covered by `multiAdapter_alex1_replay_must_not_execute`.
    function property_M1c_weighted_executions_bounded_by_deliveries() public {
        uint256 n = ghost_cumTracked.length;
        for (uint256 i; i < n; i++) {
            TrackedPair memory p = ghost_cumTracked[i];

            uint256 weighted = ghost_cumExecutionsWeighted[p.centrifugeId][p.payloadHash];
            uint256 delivs = ghost_cumDeliveries[p.centrifugeId][p.payloadHash];
            lte(weighted, delivs, "M1c: weighted-executions > cumulative-deliveries");
        }
    }

    /// @dev `countingProcessor.callCount[cId][hash]` never decreases (structurally true: the mock is unsigned).
    function property_callCount_monotonic() public {
        uint256 n = ghost_cumTracked.length;
        for (uint256 i; i < n; i++) {
            TrackedPair memory p = ghost_cumTracked[i];

            uint256 cur = countingProcessor.callCount(p.centrifugeId, p.payloadHash);
            uint256 lastSeen = ghost_cumLastSeenCallCount[p.centrifugeId][p.payloadHash];
            gte(cur, lastSeen, "callCount: decreased between handlers");
        }
    }

    // Session-id monotonicity is asserted inside `multiAdapter_reconfigure`, the only handler that mutates it.
}
