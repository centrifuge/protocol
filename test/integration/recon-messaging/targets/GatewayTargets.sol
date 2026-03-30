// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {BeforeAfter} from "../BeforeAfter.sol";
import {Asserts} from "@chimera/Asserts.sol";

abstract contract GatewayTargets is BeforeAfter, Asserts {
    /// @dev Send an outbound message. The test contract is a ward so auth passes.
    ///      unpaidMode=true avoids needing ETH; SimpleAdapter.estimate() returns 0 anyway.
    function gateway_send(uint16 centrifugeId, bytes calldata message) public {
        require(message.length > 0 && message.length <= 200, "invalid message");
        gateway.send(centrifugeId, message, true, address(this));
    }

    /// @dev Retry a failed message. Requires failedMessages > 0 so the call succeeds.
    function gateway_retry(uint16 centrifugeId, bytes calldata message) public {
        require(message.length > 0, "empty message");
        bytes32 msgHash = keccak256(message);
        require(gateway.failedMessages(centrifugeId, msgHash) > 0, "not a failed message");
        gateway.retry(centrifugeId, message);
    }

    /// @dev Attempt to retry a message that has NOT failed — must revert with NotFailedMessage.
    ///      If it doesn't revert, property G3 fires.
    function gateway_retry_nonFailed_mustRevert(uint16 centrifugeId, bytes calldata message) public {
        require(message.length > 0, "empty message");
        bytes32 msgHash = keccak256(message);
        require(gateway.failedMessages(centrifugeId, msgHash) == 0, "skip: has failed entry");

        try gateway.retry(centrifugeId, message) {
            t(false, "G3: retry succeeded on non-failed message");
        } catch {}
    }

    /// @dev Block / unblock outgoing messages for GLOBAL_POOL.
    function gateway_blockOutgoing(uint16 centrifugeId, bool blocked) public {
        gateway.blockOutgoing(centrifugeId, GLOBAL_POOL, blocked);
    }

    /// @dev Pause / unpause the protocol. Useful for covering the Paused() revert path.
    function gateway_setPaused(bool paused) public {
        mockProtocolPauser.setPaused(paused);
    }

    /// @dev Configure CountingProcessor to reject a specific hash, causing the next gateway.handle()
    ///      invocation for that hash to fail and increment failedMessages.
    function gateway_setProcessorFail(uint16 centrifugeId, bytes32 msgHash, bool fail) public {
        countingProcessor.setFail(centrifugeId, msgHash, fail);
    }

    // ─── Negative enforcement targets ────────────────────────────────────────

    /// @dev G5 – Inbound handle must revert when protocol is paused.
    ///      Pre-delivers one vote to approach threshold, pauses, then delivers the second
    ///      vote which triggers gateway.handle() — which should revert due to pause.
    function gateway_handle_whenPaused_mustRevert(bytes calldata payload) public {
        require(payload.length > 0 && payload.length <= 200, "invalid payload");
        require(!mockProtocolPauser.paused(), "already paused");

        // First delivery — vote stored, threshold not yet met
        adapter0.deliver(payload);

        mockProtocolPauser.setPaused(true);

        // Second delivery reaches threshold → gateway.handle → should revert (Paused)
        try adapter1.deliver(payload) {
            t(false, "G5: deliver succeeded while paused");
        } catch {}

        mockProtocolPauser.setPaused(false);
    }

    /// @dev G5b – retry must revert when protocol is paused.
    function gateway_retry_whenPaused_mustRevert(bytes calldata message) public {
        require(message.length > 0, "empty message");
        bytes32 msgHash = keccak256(message);
        require(gateway.failedMessages(REMOTE_CENTRIFUGE_ID, msgHash) > 0, "not a failed message");
        require(!mockProtocolPauser.paused(), "already paused");

        mockProtocolPauser.setPaused(true);

        try gateway.retry(REMOTE_CENTRIFUGE_ID, message) {
            t(false, "G5b: retry succeeded while paused");
        } catch {}

        mockProtocolPauser.setPaused(false);
    }

    /// @dev G6 – send must revert when outgoing is blocked for that centrifugeId.
    function gateway_send_whenBlocked_mustRevert(uint16 centrifugeId, bytes calldata message) public {
        require(message.length > 0 && message.length <= 200, "invalid message");
        require(!gateway.isOutgoingBlocked(centrifugeId, GLOBAL_POOL), "already blocked");

        gateway.blockOutgoing(centrifugeId, GLOBAL_POOL, true);

        try gateway.send(centrifugeId, message, true, address(this)) {
            t(false, "G6: send succeeded while outgoing blocked");
        } catch {}

        gateway.blockOutgoing(centrifugeId, GLOBAL_POOL, false);
    }
}
