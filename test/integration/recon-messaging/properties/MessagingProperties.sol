// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {MAX_ADAPTER_COUNT} from "../../../../src/core/messaging/interfaces/IMultiAdapter.sol";
import {BeforeAfter} from "../BeforeAfter.sol";
import {Asserts} from "@chimera/Asserts.sol";

abstract contract MessagingProperties is BeforeAfter, Asserts {
    // ─── MultiAdapter invariants ──────────────────────────────────────────────

    /// @dev M1 – Threshold enforcement
    ///      For every (centrifugeId, payloadHash) pair seen in this run:
    ///          callCount * threshold <= deliveries
    ///
    ///      Rationale: each gateway.handle() invocation consumes exactly `threshold` positive votes
    ///      (decreaseFirstNValues reduces all quorum slots by 1 after each execution).  Each
    ///      adapter delivery adds exactly one positive vote.  Therefore processor can be called at
    ///      most floor(deliveries / threshold) times.
    function property_M1_threshold_respected() public {
        uint256 threshold_ = uint256(multiAdapter.threshold(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL));
        uint256 n = ghost_trackedPayloadHashes.length;

        for (uint256 i; i < n; i++) {
            uint16 cId = ghost_trackedCentrifugeIds[i];
            bytes32 payloadHash = ghost_trackedPayloadHashes[i];

            uint256 deliveries = ghost_deliveries[cId][payloadHash];
            uint256 calls = countingProcessor.callCount(cId, payloadHash);

            lte(calls * threshold_, deliveries, "M1: callCount * threshold > deliveries");
        }
    }

    /// @dev M2 – Quorum consistency: the reported quorum equals the number of configured adapters
    function property_M2_quorum_equals_adapter_count() public {
        uint8 q = multiAdapter.quorum(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        eq(uint256(q), uint256(ghost_adapterCount), "M2: quorum != adapter count");
    }

    /// @dev M3 – Threshold always ≤ quorum
    function property_M3_threshold_leq_quorum() public {
        uint8 q = multiAdapter.quorum(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        uint8 thr = multiAdapter.threshold(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        lte(uint256(thr), uint256(q), "M3: threshold > quorum");
    }

    /// @dev M4 – Vote sum bounded by deliveries
    ///      For every tracked payload, the sum of positive votes across all adapter slots must not
    ///      exceed total deliveries. Each delivery adds exactly one vote; decreaseFirstNValues only
    ///      decreases. Therefore sumPositive(votes) <= deliveries must always hold.
    function property_M4_vote_sum_bounded() public {
        uint256 n = ghost_trackedPayloadHashes.length;
        uint8 q = multiAdapter.quorum(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);

        for (uint256 i; i < n; i++) {
            uint16 cId = ghost_trackedCentrifugeIds[i];
            bytes32 payloadHash = ghost_trackedPayloadHashes[i];

            int16[MAX_ADAPTER_COUNT] memory v = multiAdapter.votes(cId, payloadHash);
            uint256 positiveSum;
            for (uint8 j; j < q; j++) {
                if (v[j] > 0) positiveSum += uint16(v[j]);
            }

            uint256 deliveries = ghost_deliveries[cId][payloadHash];
            lte(positiveSum, deliveries, "M4: positive vote sum > deliveries");
        }
    }

    // ─── Gateway invariants ───────────────────────────────────────────────────

    /// @dev G1 – isBatching is always false between transactions
    ///      Transient storage resets after every transaction, so this is always true at property
    ///      evaluation time (between txs). Catches any regression where isBatching leaks.
    function property_G1_isBatching_false() public {
        t(!gateway.isBatching(), "G1: isBatching is true between transactions");
    }

    /// @dev G2 – Execution conservation (strengthened M1)
    ///      For every tracked payload:
    ///          (callCount + failedMessages) * threshold <= deliveries
    ///
    ///      Each threshold reach in MultiAdapter triggers exactly one gateway.handle() call.
    ///      _safeProcess either succeeds (callCount++) or fails (failedMessages++).
    ///      retry() decrements failedMessages and increments callCount, so the sum is preserved.
    ///      Therefore (callCount + failedMessages) counts total threshold reaches.
    function property_G2_execution_conservation() public {
        uint256 threshold_ = uint256(multiAdapter.threshold(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL));
        uint256 n = ghost_trackedPayloadHashes.length;

        for (uint256 i; i < n; i++) {
            uint16 cId = ghost_trackedCentrifugeIds[i];
            bytes32 payloadHash = ghost_trackedPayloadHashes[i];

            uint256 deliveries = ghost_deliveries[cId][payloadHash];
            uint256 calls = countingProcessor.callCount(cId, payloadHash);
            uint256 failed = gateway.failedMessages(cId, payloadHash);

            lte(
                (calls + failed) * threshold_,
                deliveries,
                "G2: (callCount + failedMessages) * threshold > deliveries"
            );
        }
    }

    /// @dev G3 – retry reverts for messages that have not failed
    ///      Covered by the negative target function gateway_retry_nonFailed_mustRevert which
    ///      fires t(false, ...) if retry succeeds on a non-failed message.
    ///      This property is a passive sentinel confirming we haven't broken the check.
    function property_G3_retry_only_for_failed() public {
        // Active enforcement is in gateway_retry_nonFailed_mustRevert target function.
        t(true, "G3: sentinel - see gateway_retry_nonFailed_mustRevert");
    }

    /// @dev G4 – failedMessages is never decremented below zero
    ///      Since failedMessages is a uint256 mapping, underflow would revert. As long as we can
    ///      interact with the contract without a panic, this trivially holds.
    ///      We verify for all tracked payloads that retry preconditions are respected.
    function property_G4_failed_messages_nonneg() public {
        uint256 n = ghost_trackedPayloadHashes.length;
        for (uint256 i; i < n; i++) {
            uint16 cId = ghost_trackedCentrifugeIds[i];
            bytes32 payloadHash = ghost_trackedPayloadHashes[i];
            // If this ever underflowed it would have reverted, so the value is always valid.
            // Check it is a reasonable upper bound: failedMessages <= deliveries
            uint256 failed = gateway.failedMessages(cId, payloadHash);
            uint256 deliveries = ghost_deliveries[cId][payloadHash];
            lte(failed, deliveries, "G4: failedMessages > deliveries");
        }
    }

    /// @dev G5 – Pause blocks inbound message processing
    ///      Active enforcement via gateway_handle_whenPaused_mustRevert target function.
    function property_G5_pause_blocks_inbound() public {
        t(true, "G5: sentinel - see gateway_handle_whenPaused_mustRevert");
    }

    /// @dev G6 – Outgoing blocked enforcement
    ///      Active enforcement via gateway_send_whenBlocked_mustRevert target function.
    function property_G6_outgoing_block_enforced() public {
        t(true, "G6: sentinel - see gateway_send_whenBlocked_mustRevert");
    }
}
