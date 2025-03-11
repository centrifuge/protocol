// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import {Asserts} from "@chimera/Asserts.sol";

import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import "src/common/Gateway.sol";

import {MockAdapter} from "test/common/mocks/MockAdapter.sol";

// What happens if we add more adapters later?

// Quorum = Every active router
// 1 MSG Router -> Handled if 1 Message and 2 proofs

// 1 Proof + 1 Msg router
// 1 Message sent
// Add 1 router
// Recovery Logic -> Resend

/**
 * 1) Understand better
 *   2) Increase coverage
 */
abstract contract Setup is BaseSetup, Asserts {
    /// TODO: Consider shared storage
    Gateway routerAggregator;

    // NOTE: Actor tracking
    address gateway = address(this);

    uint256 RECON_ADAPTERS = 2;

    IAdapter[] adapters;

    // todo: create some sort of a function that is usable
    bytes[] messages;
    mapping(bytes32 => bool) doesMessageExists;

    mapping(bytes32 => uint256) messageSentCount;
    mapping(bytes32 => uint256) proofSentCount;

    mapping(bytes32 => uint256) messageReceivedCount;

    mapping(bytes32 => uint256) messageRecoveredCount;

    // How many times does the gateway receive
    // TODO: Implement

    function handle(bytes calldata message) external {
        require(msg.sender == address(routerAggregator));

        // Verify that it already exists
        t(doesMessageExists[keccak256(message)], "Handle was called by aggregator with a non existant message");

        messageReceivedCount[keccak256(message)] += 1;
    }

    function setup() internal virtual override {
        routerAggregator = new Gateway(IRoot(address(0)), IGasService(address(0)));

        // Given config, add adapters
        for (uint256 i = 0; i < RECON_ADAPTERS; i++) {
            adapters.push(new MockAdapter(routerAggregator));
        }

        routerAggregator.file("adapters", adapters);
    }
}
