// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {TargetFunctions} from "./TargetFunctions.sol";

import {Test} from "forge-std/Test.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

// forge test --match-contract CryticMessagingToFoundry -vv
contract CryticMessagingToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    // forge test --match-test test_crytic -vvv
    function test_crytic() public {}

    // ─── Smoke tests ─────────────────────────────────────────────────────────

    /// @dev Deliver threshold times and confirm the processor was called once
    function test_deliver_to_threshold_executes_processor() public {
        bytes memory payload = abi.encode(uint256(42));

        this.multiAdapter_deliver(0, payload); // adapter0 votes
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, keccak256(payload)), 0);

        this.multiAdapter_deliver(1, payload); // adapter1 votes → threshold=2 reached
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, keccak256(payload)), 1);

        property_M1_threshold_respected();
    }

    /// @dev Delivering the same payload via the same adapter twice should NOT cause double execution
    function test_duplicate_same_adapter_no_double_execution() public {
        bytes memory payload = abi.encode(uint256(99));

        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(0, payload); // second vote from same adapter — votes[0] = 2, others = 0
        // Only 1 positive slot despite 2 deliveries; threshold=2 requires 2 *different* adapters
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, keccak256(payload)), 0);

        property_M1_threshold_respected();
    }

    /// @dev Retry on a non-failed message must revert
    function test_retry_nonFailed_reverts() public {
        bytes memory message = abi.encode(uint256(7));
        this.gateway_retry_nonFailed_mustRevert(REMOTE_CENTRIFUGE_ID, message);
    }

    /// @dev After a forced failure, failedMessages increments; retry decrements and re-executes
    function test_failed_message_retry_flow() public {
        bytes memory payload = abi.encode(uint256(55));
        bytes32 payloadHash = keccak256(payload);

        // Configure processor to fail for this hash
        gateway_setProcessorFail(REMOTE_CENTRIFUGE_ID, payloadHash, true);

        // Deliver to threshold — gateway will call processor which reverts → failedMessages++
        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(1, payload);

        assertGt(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, payloadHash), 0);

        // Fix the processor and retry
        gateway_setProcessorFail(REMOTE_CENTRIFUGE_ID, payloadHash, false);
        this.gateway_retry(REMOTE_CENTRIFUGE_ID, payload);

        assertEq(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, payloadHash), 0);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 1);
    }

    // ─── G2: Execution conservation ──────────────────────────────────────────

    /// @dev G2 holds after a normal delivery + after a failure/retry cycle
    function test_G2_execution_conservation() public {
        bytes memory payload = abi.encode(uint256(100));
        bytes32 payloadHash = keccak256(payload);

        // Normal delivery — adapter0 + adapter1 reach threshold
        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(1, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 1);
        assertEq(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, payloadHash), 0);
        property_G2_execution_conservation();

        // Force a failure on next threshold reach.
        // After first execution votes are [0, 0, -1] (decreaseFirstNValues consumed all 3 slots).
        // Need adapter0 + adapter1 again to reach threshold (adapter2 starts at -1, needs 2 votes
        // just to become positive).
        gateway_setProcessorFail(REMOTE_CENTRIFUGE_ID, payloadHash, true);
        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(1, payload);
        // callCount=1, failedMessages=1, deliveries=4, (1+1)*2=4 <= 4
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 1);
        assertEq(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, payloadHash), 1);
        property_G2_execution_conservation();

        // Retry succeeds
        gateway_setProcessorFail(REMOTE_CENTRIFUGE_ID, payloadHash, false);
        this.gateway_retry(REMOTE_CENTRIFUGE_ID, payload);
        // callCount=2, failedMessages=0, (2+0)*2=4 <= 4
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 2);
        assertEq(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, payloadHash), 0);
        property_G2_execution_conservation();
    }

    // ─── M4: Vote sum bounded ────────────────────────────────────────────────

    /// @dev Vote sum stays bounded after partial delivery (below threshold)
    function test_M4_vote_sum_bounded() public {
        bytes memory payload = abi.encode(uint256(200));

        this.multiAdapter_deliver(0, payload);
        property_M4_vote_sum_bounded();

        // Same adapter again — votes[0]=2, positiveSum=2, deliveries=2
        this.multiAdapter_deliver(0, payload);
        property_M4_vote_sum_bounded();

        // Second adapter reaches threshold, votes consumed
        this.multiAdapter_deliver(1, payload);
        property_M4_vote_sum_bounded();
    }

    // ─── G5: Pause enforcement ───────────────────────────────────────────────

    /// @dev Delivery reaching threshold must revert when paused.
    ///      Pause only blocks gateway.handle(), which fires when threshold is met.
    ///      Pre-deliver one vote, then pause, then deliver the second to hit threshold.
    function test_G5_pause_blocks_inbound() public {
        bytes memory payload = abi.encode(uint256(300));

        // First delivery (not paused) — stores vote, threshold not met
        this.multiAdapter_deliver(0, payload);

        // Pause protocol
        mockProtocolPauser.setPaused(true);

        // Second delivery reaches threshold → gateway.handle → reverts due to Paused
        try adapter1.deliver(payload) {
            // If it doesn't revert, the pause is not enforced
            assertTrue(false, "G5: deliver succeeded while paused");
        } catch {}

        mockProtocolPauser.setPaused(false);
    }

    /// @dev Retry must revert when paused
    function test_G5b_pause_blocks_retry() public {
        bytes memory payload = abi.encode(uint256(301));
        bytes32 payloadHash = keccak256(payload);

        // Create a failed message first
        gateway_setProcessorFail(REMOTE_CENTRIFUGE_ID, payloadHash, true);
        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(1, payload);
        assertGt(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, payloadHash), 0);

        gateway_setProcessorFail(REMOTE_CENTRIFUGE_ID, payloadHash, false);
        this.gateway_retry_whenPaused_mustRevert(payload);
    }

    // ─── G6: Outgoing block enforcement ──────────────────────────────────────

    /// @dev Send must revert when outgoing is blocked
    function test_G6_outgoing_block_enforced() public {
        bytes memory message = abi.encode(uint256(400));
        this.gateway_send_whenBlocked_mustRevert(REMOTE_CENTRIFUGE_ID, message);
    }

    // ─── Adapter reconfiguration ─────────────────────────────────────────────

    /// @dev Reconfiguring adapters invalidates pending votes
    function test_reconfigure_invalidates_pending_votes() public {
        bytes memory payload = abi.encode(uint256(500));
        bytes32 payloadHash = keccak256(payload);

        // Deliver via adapter0 (1 vote, below threshold=2)
        this.multiAdapter_deliver(0, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 0);

        // Reconfigure (same adapters, same threshold) — this increments sessionId
        this.multiAdapter_reconfigure(2, 1); // count=3, threshold=2

        // Deliver via adapter1 — old vote from adapter0 is invalidated, so still below threshold
        this.multiAdapter_deliver(1, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 0);

        // Deliver via adapter0 again — now 2 distinct adapters in new session → threshold reached
        this.multiAdapter_deliver(0, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 1);

        property_M1_threshold_respected();
        property_M2_quorum_equals_adapter_count();
        property_M3_threshold_leq_quorum();
    }

    /// @dev Reconfigure to threshold=1 — single adapter delivery should execute immediately
    function test_reconfigure_threshold_one() public {
        bytes memory payload = abi.encode(uint256(501));
        bytes32 payloadHash = keccak256(payload);

        // Set threshold=1, count=1 (only adapter0)
        this.multiAdapter_reconfigure(0, 0); // count=1, threshold=1

        this.multiAdapter_deliver(0, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 1);

        property_G2_execution_conservation();
    }
}
