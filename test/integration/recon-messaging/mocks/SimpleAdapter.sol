// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAdapter} from "../../../../src/core/messaging/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../../../src/core/messaging/interfaces/IMessageHandler.sol";

/// @dev Simulates a GMP adapter. Calling deliver() mimics inbound delivery from a remote chain.
contract SimpleAdapter is IAdapter {
    IMessageHandler public immutable multiAdapter;
    uint16 public immutable remoteChainId;

    constructor(uint16 remoteChainId_, IMessageHandler multiAdapter_) {
        remoteChainId = remoteChainId_;
        multiAdapter = multiAdapter_;
    }

    /// @dev Called by targets to simulate a message arriving from the remote chain via this adapter.
    function deliver(bytes calldata payload) external {
        multiAdapter.handle(remoteChainId, payload);
    }

    // ── IAdapter ──────────────────────────────────────────────────────────────

    function send(uint16, bytes calldata, uint256, address) external payable returns (bytes32) {
        return bytes32(0);
    }

    function estimate(uint16, bytes calldata, uint256) external pure returns (uint256) {
        return 0;
    }
}
