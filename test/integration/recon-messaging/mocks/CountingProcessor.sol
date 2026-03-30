// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IMessageHandler} from "../../../../src/core/messaging/interfaces/IMessageHandler.sol";

/// @dev Counts handle() invocations. Can be configured to revert for specific hashes to exercise
///      the Gateway's failedMessages path.
contract CountingProcessor is IMessageHandler {
    mapping(uint16 centrifugeId => mapping(bytes32 msgHash => uint256)) public callCount;
    mapping(uint16 centrifugeId => mapping(bytes32 msgHash => bool)) public shouldFail;

    function handle(uint16 centrifugeId, bytes memory message) external {
        bytes32 msgHash = keccak256(message);
        require(!shouldFail[centrifugeId][msgHash], "CountingProcessor: forced failure");
        callCount[centrifugeId][msgHash]++;
    }

    function setFail(uint16 centrifugeId, bytes32 msgHash, bool fail) external {
        shouldFail[centrifugeId][msgHash] = fail;
    }
}
