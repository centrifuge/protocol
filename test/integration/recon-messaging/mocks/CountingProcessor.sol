// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {IMessageParser} from "../../../../src/core/messaging/interfaces/IMessageParser.sol";
import {IMessageHandler} from "../../../../src/core/messaging/interfaces/IMessageHandler.sol";

/// @dev Counts handle() invocations; can be forced to revert to exercise the Gateway's failedMessages path.
///      Also serves the framing view, as MessageProcessor does: single-message batches, all routed via
///      GLOBAL_POOL.
contract CountingProcessor is IMessageHandler, IMessageParser {
    /// @dev Source-restricted messages are `0xFE ++ bytes2(requiredSource) ++ ...`; encoded in the message
    ///      because the interface pins this `pure`. Anything else returns 0 = any source permitted.
    bytes1 public constant SOURCE_RESTRICTED_MAGIC = 0xFE;

    mapping(uint16 centrifugeId => mapping(bytes32 msgHash => uint256)) public callCount;
    mapping(uint16 centrifugeId => mapping(bytes32 msgHash => bool)) public shouldFail;

    function handle(uint16 centrifugeId, bytes memory message) external {
        bytes32 msgHash = keccak256(message);
        require(!shouldFail[centrifugeId][msgHash], "CountingProcessor: forced failure");
        callCount[centrifugeId][msgHash]++;
    }

    /// @dev Intentionally unauthenticated: tests configure failure modes directly.
    function setFail(uint16 centrifugeId, bytes32 msgHash, bool fail) external {
        shouldFail[centrifugeId][msgHash] = fail;
    }

    function messageLength(bytes calldata message) external pure returns (uint16) {
        return uint16(message.length);
    }

    function messagePoolId(bytes calldata) external pure returns (PoolId) {
        return PoolId.wrap(0); // GLOBAL_POOL
    }

    /// @dev All payloads route via GLOBAL_POOL, so the `poolConfigured == false` fallback is a no-op here.
    function routePoolId(bytes calldata, bool) external pure returns (PoolId) {
        return PoolId.wrap(0); // GLOBAL_POOL
    }

    function messageSourceCentrifugeId(bytes calldata message) external pure returns (uint16) {
        if (message.length >= 3 && message[0] == SOURCE_RESTRICTED_MAGIC) {
            return uint16(bytes2(message[1:3]));
        }
        return 0;
    }
}
