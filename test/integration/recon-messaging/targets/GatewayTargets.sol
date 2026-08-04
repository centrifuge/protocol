// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {MultiAdapterTargets} from "./MultiAdapterTargets.sol";

import {IAdapter} from "../../../../src/core/messaging/interfaces/IAdapter.sol";
import {MAX_ADAPTER_COUNT} from "../../../../src/core/messaging/interfaces/IMultiAdapter.sol";

import {SimpleAdapter} from "../mocks/SimpleAdapter.sol";

abstract contract GatewayTargets is MultiAdapterTargets {
    /// @dev Send outbound; unpaidMode with zero-estimate adapters dispatches at once (fuel 0 >= cost 0).
    ///      centrifugeId is mostly clamped to the configured route; the rare escape keeps EmptyAdapterSet live.
    function gateway_send(uint16 centrifugeIdSeed, bytes calldata message) public validPayload(message) {
        uint16 cId = centrifugeIdSeed % 16 == 0 ? centrifugeIdSeed : REMOTE_CENTRIFUGE_ID;
        if (cId != REMOTE_CENTRIFUGE_ID) {
            gateway.send(cId, message, true, address(this)); // natural EmptyAdapterSet on dead routes
            return;
        }

        IAdapter[] memory list = _activeList();
        uint256[] memory sendsBefore = new uint256[](list.length);
        for (uint256 i; i < list.length; i++) {
            sendsBefore[i] = SimpleAdapter(address(list[i])).sendCount();
        }

        gateway.send(cId, message, true, address(this));

        bytes32 wrappedHash = keccak256(_wrap(message));
        for (uint256 i; i < list.length; i++) {
            SimpleAdapter a = SimpleAdapter(address(list[i]));
            eq(a.sendCount(), sendsBefore[i] + 1, "S1: send fan-out did not hit active adapter exactly once");
            t(a.lastSentPayloadHash() == wrappedHash, "S2: sent payload not wrapped with active sessionId");
        }
    }

    /// @dev Retry a failed message; with no failed entry it naturally reverts NotFailedMessage. A
    ///      successful retry executes without casting a vote, so only the execution delta is recorded.
    function gateway_retry(uint16 centrifugeIdSeed, bytes calldata message) public {
        uint16 cId = centrifugeIdSeed % 16 == 0 ? centrifugeIdSeed : REMOTE_CENTRIFUGE_ID;
        bytes memory m = _bucket(message);
        bytes32 msgHash = keccak256(m);
        uint256 failedBefore = gateway.failedMessages(cId, msgHash);

        gateway.retry(cId, m);

        // A retry re-runs an already-counted failed instance, no new votes: the quorum event was
        // credited at the failing session's threshold. Absorb the counter moves instead of re-crediting.
        _syncCumCounters(cId, msgHash);

        // When the consumed failure predates this session's baseline, its funding deliveries are not in
        // ghost_deliveries: bump the callCount baseline so the retried execution stays out of the delta.
        if (ghost_isTracked[cId][msgHash] && failedBefore <= ghost_baselineFailedMessages[cId][msgHash]) {
            ghost_baselineCallCount[cId][msgHash]++;
        }
    }

    /// @dev Discard one failed-message instance; naturally reverts NotFailedMessage with nothing to clear.
    function gateway_clearFailedMessage(bytes calldata message) public {
        bytes memory m = _bucket(message);
        bytes32 msgHash = keccak256(m);
        uint256 failedBefore = gateway.failedMessages(REMOTE_CENTRIFUGE_ID, msgHash);
        uint256 ccBefore = countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, msgHash);

        gateway.clearFailedMessage(REMOTE_CENTRIFUGE_ID, m);

        eq(
            gateway.failedMessages(REMOTE_CENTRIFUGE_ID, msgHash),
            failedBefore - 1,
            "clearFailedMessage: failedMessages not decremented by exactly 1"
        );
        eq(
            countingProcessor.callCount(REMOTE_CENTRIFUGE_ID, msgHash),
            ccBefore,
            "clearFailedMessage: message was executed"
        );

        // Discarding is not a quorum event; absorb the counter move so the next real failure is detected.
        _syncCumCounters(REMOTE_CENTRIFUGE_ID, msgHash);
    }

    function gateway_setPaused(bool paused) public {
        mockProtocolPauser.setPaused(paused);
    }

    /// @dev Make CountingProcessor reject a payload so the next handle() for it fails. Bucketed payload,
    ///      not a free bytes32 (a free hash never matches a delivery); keyed on the UNWRAPPED hash.
    function gateway_setProcessorFail(bytes memory payload, bool fail) public {
        countingProcessor.setFail(REMOTE_CENTRIFUGE_ID, keccak256(_bucket(payload)), fail);
    }

    // ─── Negative enforcement targets ────────────────────────────────────────
    // Each negative target ends with `require(false)`: successful runs count as reverted, so shrunk
    // traces stay short.

    /// @dev G7 – clearFailedMessage on a non-failed message must revert with NotFailedMessage.
    function gateway_clearFailedMessage_nonFailed_mustRevert(bytes calldata message) public {
        bytes32 msgHash = keccak256(message);
        precondition(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, msgHash) == 0);

        try gateway.clearFailedMessage(REMOTE_CENTRIFUGE_ID, message) {
            t(false, "G7: clearFailedMessage succeeded on non-failed message");
        } catch (bytes memory err) {
            t(checkError(err, "NotFailedMessage()"), "G7: wrong revert (expected NotFailedMessage)");
        }
        require(false);
    }

    /// @dev G8 – a batch claiming LOCAL origin is a forgery: anything reaching handle crossed a bridge.
    function gateway_handle_local_mustRevert(bytes calldata message) public validPayload(message) {
        // handle is `pauseable`; skip when paused so the wrong-revert check stays meaningful.
        precondition(!mockProtocolPauser.paused());

        try gateway.handle(LOCAL_CENTRIFUGE_ID, message) {
            t(false, "G8: handle accepted a locally-originated batch");
        } catch (bytes memory err) {
            t(checkError(err, "CannotBeReceivedLocally()"), "G8: wrong revert (expected CannotBeReceivedLocally)");
        }
        require(false);
    }

    /// @dev G9 – a message whose required source chain doesn't match the delivering chain must revert
    ///      SourceMismatch. The mock's `0xFE ++ bytes2(requiredSource)` prefix makes it restricted.
    function gateway_handle_sourceMismatch_mustRevert(uint16 wrongSource, bytes calldata payload)
        public
        validPayload(payload)
    {
        precondition(!mockProtocolPauser.paused());
        precondition(wrongSource != 0 && wrongSource != REMOTE_CENTRIFUGE_ID);

        bytes memory message = abi.encodePacked(mockMessageProperties.SOURCE_RESTRICTED_MAGIC(), wrongSource, payload);

        try gateway.handle(REMOTE_CENTRIFUGE_ID, message) {
            t(false, "G9: handle accepted a message from the wrong source chain");
        } catch (bytes memory err) {
            t(checkError(err, "SourceMismatch()"), "G9: wrong revert (expected SourceMismatch)");
        }
        require(false);
    }

    /// @dev G3 – retry on a non-failed message must revert with NotFailedMessage.
    function gateway_retry_nonFailed_mustRevert(uint16 centrifugeId, bytes calldata message) public {
        bytes32 msgHash = keccak256(message);
        precondition(gateway.failedMessages(centrifugeId, msgHash) == 0); // negative-test setup
        // retry is `pauseable`; skip when paused so the wrong-revert check stays meaningful.
        precondition(!mockProtocolPauser.paused());

        try gateway.retry(centrifugeId, message) {
            t(false, "G3: retry succeeded on non-failed message");
        } catch (bytes memory err) {
            t(checkError(err, "NotFailedMessage()"), "G3: wrong revert (expected NotFailedMessage)");
        }
        require(false);
    }

    /// @dev G5 – inbound handle must revert Paused: vote once below threshold, pause, deliver the second.
    function gateway_handle_whenPaused_mustRevert(bytes calldata payload) public validPayload(payload) {
        precondition(!mockProtocolPauser.paused());
        precondition(multiAdapter.threshold(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL) == 2);
        precondition(_isActive(address(adapter0)) && _isActive(address(adapter1)));
        // adapter0's pre-delivery must be the FIRST positive vote: otherwise it hits threshold before
        // the pause and adapter1's delivery returns normally, tripping a false-positive `t(false)`.
        bytes memory p = _bucket(payload);
        bytes memory wrapped = _wrap(p);
        int16[MAX_ADAPTER_COUNT] memory v = multiAdapter.votes(REMOTE_CENTRIFUGE_ID, _voteKey(wrapped));
        for (uint8 i; i < MAX_ADAPTER_COUNT; i++) {
            precondition(v[i] == 0);
        }

        _captureBaselines(REMOTE_CENTRIFUGE_ID, p);
        adapter0.deliver(wrapped);
        _recordSuccessfulDelivery(REMOTE_CENTRIFUGE_ID, p);

        mockProtocolPauser.setPaused(true);

        try adapter1.deliver(wrapped) {
            t(false, "G5: deliver succeeded while paused");
        } catch (bytes memory err) {
            t(checkError(err, "Paused()"), "G5: wrong revert (expected Paused)");
        }

        // Rolled back by `require(false)` below; kept explicit.
        mockProtocolPauser.setPaused(false);
        require(false);
    }

    /// @dev G5b – retry must revert with Paused() when the protocol is paused.
    function gateway_retry_whenPaused_mustRevert(bytes calldata message) public {
        bytes memory m = _bucket(message);
        bytes32 msgHash = keccak256(m);
        precondition(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, msgHash) > 0); // need failed entry
        precondition(!mockProtocolPauser.paused());

        mockProtocolPauser.setPaused(true);

        try gateway.retry(REMOTE_CENTRIFUGE_ID, m) {
            t(false, "G5b: retry succeeded while paused");
        } catch (bytes memory err) {
            t(checkError(err, "Paused()"), "G5b: wrong revert (expected Paused)");
        }

        mockProtocolPauser.setPaused(false);
        require(false);
    }

    /// @dev G6 – blocking the active session empties the adapter set, so send must revert EmptyAdapterSet.
    function gateway_send_whenBlocked_mustRevert(bytes calldata message) public validPayload(message) {
        // send is `pauseable`; skip when paused so the wrong-revert check stays meaningful.
        precondition(!mockProtocolPauser.paused());

        uint16 sid = multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL);
        precondition(!multiAdapter.blockedSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid));

        multiAdapter.blockSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid);

        try gateway.send(REMOTE_CENTRIFUGE_ID, message, true, address(this)) {
            t(false, "G6: send succeeded while active session blocked");
        } catch (bytes memory err) {
            t(checkError(err, "EmptyAdapterSet()"), "G6: wrong revert (expected EmptyAdapterSet)");
        }

        multiAdapter.unblockSession(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, sid);
        require(false);
    }
}
