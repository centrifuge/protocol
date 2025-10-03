// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Properties} from "../Properties.sol";
import {vm} from "@chimera/Hevm.sol";
import {MockAdapter, IAdapter} from "test/common/mocks/MockAdapter.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";

// TODO: Needs to be updated for latest version of Aggregator
abstract contract BiasedTargetFunctions is BaseTargetFunctions, Properties {
    using MessageLib for *;

    mapping(uint256 => uint256) primaryIndex;

    /// @dev Add to messsages we're trying to broadcast
    // function registerNewMessage(bytes memory message, uint8 adapterId) public {
    //     // @audit CLAMP Necessary to cap to adapters count as otherwise Medusa will send messages from random
    //     adapterId %= uint8(RECON_ADAPTERS);

    //     require(messageSentCount[keccak256(message)] == 0);
    //     messages.push(message);
    //     primaryIndex[messages.length - 1] = adapterId;
    //     doesMessageExists[keccak256(message)] = true;
    // }

    // function sendMessage(uint8 adapterId, uint256 messageIndex) public {
    //     bytes memory message = messages[messageIndex];

    //     require(primaryIndex[messageIndex] == adapterId, "not-primary-router"); // Must be primary to send message
    //     // require(messageSentCount[keccak256(message)] == 0); /// TODO looks off
    //     // I think those should be: messagesSentCount[router][message] else what's the point?
    //     MockAdapter(address(adapters[adapterId])).execute(message);
    //     messageSentCount[keccak256(message)] += 1;
    // }

    // function sendProof(uint8 adapterId, uint256 messageIndex) public {
    //     bytes memory message = messages[messageIndex];
    //     require(primaryIndex[messageIndex] != adapterId); // Must not primary to send proof
    //     // require(messageSentCount[keccak256(message)] > 0); // NOTE: Proof could be sent before or after, not sure
    // why
    //     // this exists
    //     MockAdapter(address(adapters[adapterId])).execute(_formatMessageProof(message));
    //     proofSentCount[keccak256(message)] += 1;
    // }

    // function _formatMessageProof(bytes memory message) internal pure returns (bytes memory) {
    //     return MessageLib.MessageProof(keccak256(message)).serialize();
    // }

    // TODO: Initiate Message Recover
    // SEE: function testRecoverFailedMessage() public {
    /**
     * router2.execute(
     *         abi.encodePacked(
     *             uint8(MessageLib.Call.InitiateMessageRecovery), keccak256(message), address(router1).toBytes32()
     *         )
     *     );
     */
    // Store TS
    // ExecuteMessageRecovery
    // Check that TS >= RECOVERY_CHALLENGE_PERIOD
    // Check that recovery[messageHash] is sufficiently in the future

    mapping(bytes32 => uint256) recoverMessageTime;

    // function recoverMessage(uint8 calledRouterId, uint8 recoverRouterId, uint256 messageIndex) public {
    //     messageIndex %= uint8(messages.length);
    //     calledRouterId %= uint8(RECON_ADAPTERS);
    //     recoverRouterId %= uint8(RECON_ADAPTERS);

    //     bytes memory message = messages[messageIndex];

    //     // TODO: Can we call this more than once? How would it work
    //     recoverMessageTime[keccak256(message)] = block.timestamp;

    //     // NOTE: Can we recover for self?
    //     // TODO: CHECK THIS!
    //     MockAdapter(address(adapters[calledRouterId])).execute(
    //         MessageLib.InitiateMessageRecovery({
    //             hash: keccak256(message),
    //             adapter: bytes32(bytes20(address(adapters[recoverRouterId]))),
    //             centrifugeId: 0
    //         }).serialize()
    //     );
    // }

    // function executeMessageRecovery(uint8 adapterId, uint256 messageIndex) public {
    //     adapterId %= uint8(RECON_ADAPTERS);
    //     messageIndex %= uint8(messages.length);
    //     IAdapter router = routerAggregator.adapters(CENTRIFUGE_ID, adapterId);

    //     bytes memory message = messages[messageIndex];
    //     require(recoverMessageTime[keccak256(message)] != 0);
    //     routerAggregator.executeMessageRecovery(CENTRIFUGE_ID, router, message);

    //     messageRecoveredCount[keccak256(message)] += 1;

    //     t(
    //         recoverMessageTime[keccak256(message)] + routerAggregator.RECOVERY_CHALLENGE_PERIOD() <= block.timestamp,
    //         "Challenge period must have passed"
    //     );
    // }

    // function disputeMessageRecovery(uint8 adapterId, uint256 messageIndex) public {
    //     adapterId %= uint8(RECON_ADAPTERS);
    //     messageIndex %= uint8(messages.length);
    //     IAdapter router = routerAggregator.adapters(CENTRIFUGE_ID, adapterId);

    //     bytes memory message = messages[messageIndex];
    //     routerAggregator.disputeMessageRecovery(CENTRIFUGE_ID, router, keccak256(message));

    //     recoverMessageTime[keccak256(message)] = 0; // Unset time
    // }
}
