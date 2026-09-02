// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAdapter} from "../../../../src/core/messaging/interfaces/IAdapter.sol";
import {IAdapterEntrypoint} from "../../../../src/core/messaging/interfaces/IAdapterEntrypoint.sol";

/// @dev Simulates a GMP adapter; the deliver* functions mimic inbound delivery from the remote chain.
contract SimpleAdapter is IAdapter {
    IAdapterEntrypoint public immutable multiAdapter;
    uint16 public immutable remoteChainId;

    constructor(uint16 remoteChainId_, IAdapterEntrypoint multiAdapter_) {
        remoteChainId = remoteChainId_;
        multiAdapter = multiAdapter_;
    }

    function deliver(bytes calldata payload) external {
        multiAdapter.handle(remoteChainId, payload);
    }

    /// @dev Proof-adapter path: casts a vote without executing.
    function deliverVote(bytes calldata payload) external {
        multiAdapter.vote(remoteChainId, payload);
    }

    /// @dev Deferred-execution path: consumes quorum votes if the threshold is met, else reverts NotEnoughVotes.
    function deliverExecute(bytes calldata payload) external {
        multiAdapter.execute(remoteChainId, payload);
    }

    // ── IAdapter ──────────────────────────────────────────────────────────────

    // Outbound fan-out observability (S1/S2 in GatewayTargets)
    uint256 public sendCount;
    bytes32 public lastSentPayloadHash;

    function send(uint16, bytes calldata payload, uint256, address) external payable returns (bytes32) {
        sendCount++;
        lastSentPayloadHash = keccak256(payload);
        return bytes32(0);
    }

    function estimate(uint16, bytes calldata, uint256) external pure returns (uint256) {
        return 0;
    }
}
