// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {TargetFunctions} from "./TargetFunctions.sol";

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IGateway} from "../../../src/core/messaging/interfaces/IGateway.sol";
import {IAdapterEntrypoint} from "../../../src/core/messaging/interfaces/IAdapterEntrypoint.sol";
import {IMultiAdapter, MAX_ADAPTER_COUNT} from "../../../src/core/messaging/interfaces/IMultiAdapter.sol";

import {Test} from "forge-std/Test.sol";

import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

// forge test --match-contract CryticMessagingToFoundry -vv
contract CryticMessagingToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    function test_crytic() public {}

    // ─── Smoke tests ─────────────────────────────────────────────────────────

    function test_deliver_to_threshold_executes_processor() public {
        bytes memory payload = _bucket(abi.encode(uint256(42)));

        this.multiAdapter_deliver(0, payload); // adapter0 votes
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, keccak256(payload)), 0);

        this.multiAdapter_deliver(1, payload); // adapter1 votes → threshold=2 reached
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, keccak256(payload)), 1);

        property_M1_threshold_respected();
    }

    function test_duplicate_same_adapter_no_double_execution() public {
        bytes memory payload = _bucket(abi.encode(uint256(99)));

        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(0, payload); // second vote from same adapter — votes[0] = 2, others = 0
        // Only 1 positive slot despite 2 deliveries; threshold=2 needs 2 *different* adapters.
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, keccak256(payload)), 0);

        property_M1_threshold_respected();
    }

    function test_retry_nonFailed_reverts() public {
        bytes memory message = _bucket(abi.encode(uint256(7)));
        vm.expectRevert(IGateway.NotFailedMessage.selector);
        gateway.retry(REMOTE_CENTRIFUGE_ID, message);
    }

    function test_failed_message_retry_flow() public {
        bytes memory payload = _bucket(abi.encode(uint256(55)));
        bytes32 payloadHash = keccak256(payload);

        gateway_setProcessorFail(payload, true);

        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(1, payload);

        assertGt(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, payloadHash), 0);

        gateway_setProcessorFail(payload, false);
        this.gateway_retry(REMOTE_CENTRIFUGE_ID, payload);

        assertEq(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, payloadHash), 0);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 1);
    }

    // ─── G2: Execution conservation ──────────────────────────────────────────

    function test_G2_execution_conservation() public {
        bytes memory payload = _bucket(abi.encode(uint256(100)));
        bytes32 payloadHash = keccak256(payload);

        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(1, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 1);
        assertEq(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, payloadHash), 0);
        property_G2_execution_conservation();

        // After the first execution votes are [0, 0, -1] (decreaseFirstNValues consumed all 3 slots),
        // so adapter2 would need two votes just to turn positive: use adapter0 + adapter1 again.
        gateway_setProcessorFail(payload, true);
        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(1, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 1);
        assertEq(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, payloadHash), 1);
        property_G2_execution_conservation();

        gateway_setProcessorFail(payload, false);
        this.gateway_retry(REMOTE_CENTRIFUGE_ID, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 2);
        assertEq(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, payloadHash), 0);
        property_G2_execution_conservation();
    }

    // ─── M4: Vote sum bounded ────────────────────────────────────────────────

    function test_M4_vote_sum_bounded() public {
        bytes memory payload = _bucket(abi.encode(uint256(200)));

        this.multiAdapter_deliver(0, payload);
        property_M4_vote_sum_bounded();

        this.multiAdapter_deliver(0, payload);
        property_M4_vote_sum_bounded();

        this.multiAdapter_deliver(1, payload);
        property_M4_vote_sum_bounded();
    }

    /// @dev Reading votes by the bare wrapped hash instead of keccak256(poolId ++ wrapped) hits an empty
    ///      slot and fails SILENTLY (M4 vacuous, clean-slate preconditions stop guarding): assert both.
    function test_voteKey_addresses_the_live_tally() public {
        bytes memory payload = _bucket(abi.encode(uint256(0xB01E)));
        bytes memory wrapped = _wrap(payload);

        this.multiAdapter_deliver(0, payload); // one vote, below threshold=2

        int16[MAX_ADAPTER_COUNT] memory viaVoteKey = multiAdapter.votes(REMOTE_CENTRIFUGE_ID, _voteKey(wrapped));
        assertEq(viaVoteKey[0], int16(1), "vote key does not address the live tally");

        int16[MAX_ADAPTER_COUNT] memory viaBareHash = multiAdapter.votes(REMOTE_CENTRIFUGE_ID, keccak256(wrapped));
        assertEq(viaBareHash[0], int16(0), "bare wrapped hash must no longer address any tally");

        // The pool prefix separates them, at uint64 width.
        assertEq(_voteKey(wrapped), keccak256(abi.encodePacked(uint64(0), wrapped)), "vote key encoding");
    }

    // ─── G5: Pause enforcement ───────────────────────────────────────────────

    /// @dev Pause only blocks gateway.handle(), so vote once, pause, then deliver the second to threshold.
    function test_G5_pause_blocks_inbound() public {
        // Break loudly if Setup.sol's constants change.
        require(THRESHOLD == 2 && ADAPTER_COUNT == 3, "smoke test assumes THRESHOLD=2, ADAPTER_COUNT=3");

        bytes memory payload = _bucket(abi.encode(uint256(300)));

        this.multiAdapter_deliver(0, payload);

        mockProtocolPauser.setPaused(true);

        try adapter1.deliver(_wrap(payload)) {
            assertTrue(false, "G5: deliver succeeded while paused");
        } catch (bytes memory err) {
            assertEq(bytes4(err), IGateway.Paused.selector, "G5: wrong revert (expected Paused)");
        }

        mockProtocolPauser.setPaused(false);
    }

    function test_G5b_pause_blocks_retry() public {
        bytes memory payload = _bucket(abi.encode(uint256(301)));
        bytes32 payloadHash = keccak256(payload);

        gateway_setProcessorFail(payload, true);
        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(1, payload);
        assertGt(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, payloadHash), 0);
        gateway_setProcessorFail(payload, false);

        mockProtocolPauser.setPaused(true);
        vm.expectRevert(IGateway.Paused.selector);
        gateway.retry(REMOTE_CENTRIFUGE_ID, payload);
        mockProtocolPauser.setPaused(false);
    }

    // ─── G6: Outbound block enforcement (blockSession successor) ─────────────

    /// @dev Blocking the active session empties the adapter set so send reverts; unblocking restores it.
    function test_G6_outgoing_block_enforced() public {
        bytes memory message = _bucket(abi.encode(uint256(400)));
        uint16 sid = multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);

        multiAdapter.blockSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid);
        assertTrue(multiAdapter.blockedSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid));
        vm.expectRevert(IMultiAdapter.EmptyAdapterSet.selector);
        gateway.send(REMOTE_CENTRIFUGE_ID, message, true, address(this));

        multiAdapter.unblockSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid);
        assertFalse(multiAdapter.blockedSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid));
        gateway.send(REMOTE_CENTRIFUGE_ID, message, true, address(this)); // works again
    }

    // ─── Adapter reconfiguration ─────────────────────────────────────────────

    function test_reconfigure_invalidates_pending_votes() public {
        bytes memory payload = _bucket(abi.encode(uint256(500)));
        bytes32 payloadHash = keccak256(payload);

        this.multiAdapter_deliver(0, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 0);

        // New session, same set and threshold (count=3, threshold=2).
        this.multiAdapter_reconfigure(3, 2);

        // adapter0's old-session vote is invalidated, so this is still below threshold.
        this.multiAdapter_deliver(1, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 0);

        this.multiAdapter_deliver(0, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 1);

        property_M1_threshold_respected();
        property_M2_adapter_set_integrity();
        property_M3_threshold_leq_quorum();
    }

    function test_reconfigure_threshold_one() public {
        bytes memory payload = _bucket(abi.encode(uint256(501)));
        bytes32 payloadHash = keccak256(payload);

        // count=1, threshold=1: only adapter0.
        this.multiAdapter_reconfigure(1, 1);

        this.multiAdapter_deliver(0, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, payloadHash), 1);

        property_G2_execution_conservation();
    }

    // ─── C1 / H3 regressions: a reconfigure must not trip the per-session bounds ───

    function test_C1_M1_after_threshold_increase_reconfigure() public {
        bytes memory payload = _bucket(abi.encode(uint256(7)));
        bytes32 h = keccak256(payload);

        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(1, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, h), 1);
        property_M1_threshold_respected();

        this.multiAdapter_reconfigure(3, 3);
        assertEq(uint256(multiAdapter.threshold(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL)), 3);

        // Ghosts cleared on reconfigure, so the property holds vacuously here.
        property_M1_threshold_respected();
    }

    function test_C1_G2_after_threshold_increase_reconfigure() public {
        bytes memory payload = _bucket(abi.encode(uint256(8)));

        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(1, payload);
        this.multiAdapter_reconfigure(3, 3); // count=3, threshold=3
        property_G2_execution_conservation();
    }

    function test_H3_M4_after_partial_then_reconfigure() public {
        bytes memory payload = _bucket(abi.encode(uint256(9)));

        this.multiAdapter_deliver(0, payload);
        property_M4_vote_sum_bounded();

        // Ghosts cleared; old-session votes stay in storage under the old wrapped hash.
        this.multiAdapter_reconfigure(3, 2); // count=3, threshold=2

        property_M4_vote_sum_bounded();

        this.multiAdapter_deliver(0, payload);
        property_M4_vote_sum_bounded();
    }

    // ─── M6: setAdapters error-path negative tests ───────────────────────────
    // Each case reads the target session id into a local BEFORE `vm.expectRevert`; inlining
    // `nextActiveSessionId(...)` would consume the expectation with its staticcall. These test the
    // protocol directly, since the target wrappers end in `require(false)`.

    function test_M6_setAdapters_ExceedsMax() public {
        IAdapter[] memory addrs = new IAdapter[](MAX_ADAPTER_COUNT + 1);
        for (uint8 i; i < MAX_ADAPTER_COUNT + 1; i++) {
            addrs[i] = IAdapter(address(adapter0));
        }
        uint16 next = multiAdapter.nextActiveSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        vm.expectRevert(IMultiAdapter.ExceedsMax.selector);
        multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, 1, next);
    }

    function test_M6_setAdapters_ThresholdHigherThanQuorum() public {
        IAdapter[] memory addrs = new IAdapter[](2);
        addrs[0] = IAdapter(address(adapter0));
        addrs[1] = IAdapter(address(adapter1));
        uint16 next = multiAdapter.nextActiveSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        vm.expectRevert(IMultiAdapter.ThresholdHigherThanQuorum.selector);
        multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, 3, next); // threshold > quorum
    }

    /// @dev NoDuplicatesAllowed is raised AFTER the targetSessionId check, so the correct next id matters.
    function test_M6_setAdapters_NoDuplicatesAllowed() public {
        IAdapter[] memory addrs = new IAdapter[](2);
        addrs[0] = IAdapter(address(adapter0));
        addrs[1] = IAdapter(address(adapter0)); // duplicate
        uint16 next = multiAdapter.nextActiveSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        vm.expectRevert(IMultiAdapter.NoDuplicatesAllowed.selector);
        multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, 1, next);
    }

    /// @dev M6.e – threshold 0 over a non-empty set is rejected; an EMPTY set with 0 is the disable path.
    function test_M6_setAdapters_ZeroThreshold() public {
        IAdapter[] memory addrs = new IAdapter[](2);
        addrs[0] = IAdapter(address(adapter0));
        addrs[1] = IAdapter(address(adapter1));
        uint16 next = multiAdapter.nextActiveSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        vm.expectRevert(IMultiAdapter.ZeroThreshold.selector);
        multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, 0, next);

        multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, new IAdapter[](0), 0, next);
        assertEq(multiAdapter.quorum(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL), 0);
    }

    /// @dev M6.f — the targetSessionId must equal the pool's next session id, in both directions.
    function test_M6_setAdapters_UnexpectedSessionId() public {
        IAdapter[] memory addrs = new IAdapter[](1);
        addrs[0] = IAdapter(address(adapter0));

        uint16 active = multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        uint16 next = multiAdapter.nextActiveSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        assertEq(next, active + 1, "nextActiveSessionId != activeSessionId + 1");

        // Stale: the already-active session.
        vm.expectRevert(IMultiAdapter.UnexpectedSessionId.selector);
        multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, 1, active);

        // Leap-ahead: skipping a session.
        vm.expectRevert(IMultiAdapter.UnexpectedSessionId.selector);
        multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, 1, next + 1);

        multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, 1, next);
        assertEq(multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL), next);
    }

    // ─── Cross-session invariants (cumulative ghosts) ────────────────────────

    /// @dev M1c — cumulative weighted-execution ledger holds across a reconfigure.
    function test_M1c_holds_across_reconfigure() public {
        bytes memory payload = _bucket(abi.encode(uint256(13)));

        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(1, payload);
        property_M1c_weighted_executions_bounded_by_deliveries();

        // Lower the threshold: count=2, threshold=1.
        this.multiAdapter_reconfigure(2, 1);
        property_M1c_weighted_executions_bounded_by_deliveries();

        this.multiAdapter_deliver(1, payload);
        property_M1c_weighted_executions_bounded_by_deliveries();
    }

    function test_callCount_monotonic() public {
        bytes memory payload = _bucket(abi.encode(uint256(14)));
        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(1, payload);
        property_callCount_monotonic();

        this.multiAdapter_reconfigure(3, 3);
        property_callCount_monotonic();
    }

    function test_oldAdapter_rejects_after_reconfigure() public {
        // count=1, threshold=1: only adapter0 active.
        this.multiAdapter_reconfigure(1, 1);

        bytes memory wrapped = _wrap(abi.encode(uint256(15)));
        vm.expectRevert(IMultiAdapter.InvalidAdapter.selector);
        adapter1.deliver(wrapped);
        vm.expectRevert(IMultiAdapter.InvalidAdapter.selector);
        adapter2.deliver(wrapped);
    }

    // ─── vote()/execute() split (proof-adapter path) ─────────────────────────

    /// @dev vote() accumulates votes without ever executing; a subsequent execute() consumes them.
    function test_vote_then_execute_flow() public {
        bytes memory payload = _bucket(abi.encode(uint256(600)));
        bytes32 hash = keccak256(payload);

        this.multiAdapter_vote(0, payload);
        this.multiAdapter_vote(1, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, hash), 0);
        property_M4_vote_sum_bounded();

        this.multiAdapter_execute(0, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, hash), 1);

        property_M1_threshold_respected();
        property_G2_execution_conservation();
        property_M1c_weighted_executions_bounded_by_deliveries();
    }

    function test_execute_belowThreshold_reverts() public {
        bytes memory payload = _bucket(abi.encode(uint256(601)));
        this.multiAdapter_vote(0, payload); // 1 vote < threshold 2

        // _wrap() staticcalls multiAdapter, so it must run BEFORE vm.expectRevert.
        bytes memory wrapped = _wrap(payload);
        vm.expectRevert(IAdapterEntrypoint.NotEnoughVotes.selector);
        adapter0.deliverExecute(wrapped);
    }

    // ─── blockSession / unblockSession ───────────────────────────────────────

    /// @dev Blocking a historical session kills stale-sessionId replays whose config is still resolvable.
    function test_blockSession_kills_stale_replay() public {
        bytes memory payload = _bucket(abi.encode(uint256(700)));
        uint16 oldSid = multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        bytes memory staleWrapped = _wrap(payload);

        this.multiAdapter_reconfigure(3, 2); // new session; old config stays resolvable

        // Pre-block: the stale delivery still lands as an old-session vote, 1 < threshold 2.
        adapter1.deliver(staleWrapped);

        multiAdapter.blockSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, oldSid);

        vm.expectRevert(IMultiAdapter.InvalidAdapter.selector);
        adapter2.deliver(staleWrapped);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, keccak256(payload)), 0);
    }

    function test_blockSession_unconfigured_reverts() public {
        uint16 active = multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        vm.expectRevert(IMultiAdapter.SessionNotConfigured.selector);
        multiAdapter.blockSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, active + 1);
    }

    function test_unblockSession_notBlocked_reverts() public {
        uint16 active = multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        vm.expectRevert(IMultiAdapter.SessionNotBlocked.selector);
        multiAdapter.unblockSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, active);
    }

    // ─── updateManager / manager-driven handle (MA1) ─────────────────────────

    /// @dev An enabled manager can submit for configured adapters and reach quorum alone; revoking cuts it.
    function test_updateManager_manager_delivers_on_behalf() public {
        bytes memory payload = _bucket(abi.encode(uint256(1000)));
        bytes32 hash = keccak256(payload);

        bytes memory wrapped = _wrap(payload);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        managerActor.handleAs(REMOTE_CENTRIFUGE_ID, wrapped, IAdapter(address(adapter0)));

        this.multiAdapter_updateManager(true);
        this.multiAdapter_managerDeliver(0, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, hash), 0);
        this.multiAdapter_managerDeliver(1, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, hash), 1);

        property_M1_threshold_respected();
        property_G2_execution_conservation();

        this.multiAdapter_updateManager(false);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        managerActor.handleAs(REMOTE_CENTRIFUGE_ID, wrapped, IAdapter(address(adapter0)));
    }

    // ─── clearFailedMessage (G7) ─────────────────────────────────────────────

    /// @dev clearFailedMessage discards a failed instance without executing; it can no longer be retried.
    function test_clearFailedMessage_flow() public {
        bytes memory payload = _bucket(abi.encode(uint256(800)));
        bytes32 hash = keccak256(payload);

        gateway_setProcessorFail(payload, true);
        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(1, payload);
        assertEq(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, hash), 1);

        this.gateway_clearFailedMessage(payload);
        assertEq(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, hash), 0);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, hash), 0);

        vm.expectRevert(IGateway.NotFailedMessage.selector);
        gateway.retry(REMOTE_CENTRIFUGE_ID, payload);

        property_G2_execution_conservation();
        property_G4_failed_messages_bounded();
    }

    // ─── Source-chain enforcement (G8/G9) ────────────────────────────────────

    function test_handle_local_origin_reverts() public {
        vm.expectRevert(IGateway.CannotBeReceivedLocally.selector);
        gateway.handle(LOCAL_CENTRIFUGE_ID, abi.encode(uint256(900)));
    }

    /// @dev A source-restricted message (magic 0xFE ++ bytes2(source)) is rejected from the wrong chain.
    function test_handle_source_enforcement() public {
        bytes memory restrictedWrong = abi.encodePacked(bytes1(0xFE), LOCAL_CENTRIFUGE_ID, uint256(901));
        vm.expectRevert(IGateway.SourceMismatch.selector);
        gateway.handle(REMOTE_CENTRIFUGE_ID, restrictedWrong);

        bytes memory restrictedRight = abi.encodePacked(bytes1(0xFE), REMOTE_CENTRIFUGE_ID, uint256(901));
        gateway.handle(REMOTE_CENTRIFUGE_ID, restrictedRight);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, keccak256(restrictedRight)), 1);
    }

    // ─── §4.1: cross-session retry must not trip per-session bounds ──────────

    /// @dev Retrying a failure funded in a PREVIOUS session (per-session ghosts wiped) yields a callCount
    ///      delta with no matching deliveries; `gateway_retry` bumps the baseline to keep M1/G2 sound.
    function test_M1_G2_cross_session_retry_no_false_positive() public {
        bytes memory payload = _bucket(abi.encode(uint256(1100)));
        bytes32 hash = keccak256(payload);

        gateway_setProcessorFail(payload, true);
        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(1, payload);
        assertEq(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, hash), 1);
        gateway_setProcessorFail(payload, false);

        // Reconfigure: per-session ghosts wiped, the funding deliveries forgotten.
        this.multiAdapter_reconfigure(3, 2);

        this.multiAdapter_deliver(0, payload);
        this.gateway_retry(REMOTE_CENTRIFUGE_ID, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, hash), 1);

        property_M1_threshold_respected();
        property_G2_execution_conservation();
        property_M1c_weighted_executions_bounded_by_deliveries();
    }

    // ─── S1/S2: outbound fan-out observability ───────────────────────────────

    /// @dev Send fan-out hits every active adapter exactly once with the session-wrapped payload.
    function test_send_fanout_hits_all_active_adapters_wrapped() public {
        bytes memory message = _bucket(abi.encode(uint256(1200)));

        this.gateway_send(REMOTE_CENTRIFUGE_ID, message); // asserts S1/S2 inline
        assertEq(adapter0.sendCount(), 1);
        assertEq(adapter1.sendCount(), 1);
        assertEq(adapter2.sendCount(), 1);
        assertEq(adapter0.lastSentPayloadHash(), keccak256(_wrap(message)));

        // Shrink to [adapter0]: only the active adapter is hit.
        this.multiAdapter_reconfigure(1, 1);
        this.gateway_send(REMOTE_CENTRIFUGE_ID, message);
        assertEq(adapter0.sendCount(), 2);
        assertEq(adapter1.sendCount(), 1);
        assertEq(adapter2.sendCount(), 1);
        assertEq(adapter0.lastSentPayloadHash(), keccak256(_wrap(message))); // new session prefix
    }

    // ─── Alex-1 cross-session replay regression ──────────────────────────────

    /// @dev Cross-session replay must not re-execute: stale bytes count under the old session's threshold.
    function test_alex1_replay_does_not_reexecute() public {
        bytes memory payload = _bucket(abi.encode(uint256(0xa1ec1)));
        // keepIdx=0: adapter0 stays in the post-reconfigure single-adapter set and replays.
        this.multiAdapter_alex1_replay_must_not_execute(0, payload);
    }

    /// @dev Old-session votes ([2,0,0] here) live under a hash M4 never reads after the reconfigure.
    function test_property_M4_no_stale_vote_pollution_across_reconfigure() public {
        bytes memory payload = _bucket(abi.encode(uint256(0xc44832b)));
        this.multiAdapter_deliver(0, payload);
        this.multiAdapter_deliver(0, payload); // same adapter twice — below threshold, votes [2,0,0]
        this.multiAdapter_reconfigure(0, 0); // count=1, threshold=1 → new session
        this.multiAdapter_deliver(0, payload); // executes immediately under the new session
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, keccak256(payload)), 1);
        property_M4_vote_sum_bounded();
    }

    /// @dev A retry re-execution must not be credited at the CURRENT threshold: when the threshold rises
    ///      between the failing delivery and the retry, that would push weighted above cumDeliveries.
    function test_property_M1c_cross_session_retry_threshold_increase() public {
        bytes memory payload = _bucket(abi.encode(uint256(0xdead)));
        bytes32 h = keccak256(payload);

        this.multiAdapter_reconfigure(0, 0); // count=1, threshold=1

        // A SINGLE delivery funds this failure: cumDeliveries=1, weighted=0.
        gateway_setProcessorFail(payload, true);
        this.multiAdapter_deliver(0, payload);
        assertEq(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, h), 1);

        this.multiAdapter_reconfigure(3, 2); // count=3, threshold=2

        // Retry re-executes the message without casting a new vote.
        gateway_setProcessorFail(payload, false);
        this.gateway_retry(REMOTE_CENTRIFUGE_ID, payload);
        assertEq(countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, h), 1);

        // The fail at threshold 1 was credited weighted=1; the retry credits nothing, matching cumDeliveries.
        property_M1c_weighted_executions_bounded_by_deliveries();
    }
}
