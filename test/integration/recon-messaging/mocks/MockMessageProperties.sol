// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {IMessageProperties} from "../../../../src/core/messaging/interfaces/IMessageProperties.sol";

/// @dev Every payload is a single-message batch belonging to GLOBAL_POOL.
contract MockMessageProperties is IMessageProperties {
    /// @dev Must exceed FAILURE_GAS_RESERVE so `_safeProcess` forwards positive gas to the processor
    uint128 public constant PROCESSING_GAS_LIMIT = 200_000;
    uint128 public constant MAX_BATCH_GAS = 10_000_000;
    /// @dev Reserved per message to record a processor failure; subtracted from PROCESSING_GAS_LIMIT.
    uint128 public constant FAILURE_GAS_RESERVE = 35_000;

    function messageOverallGasLimit(uint16, bytes calldata) external pure returns (uint128) {
        return 0;
    }

    function messageProcessingGasLimit(uint16, bytes calldata) external pure returns (uint128) {
        return PROCESSING_GAS_LIMIT;
    }

    function maxBatchGasLimit(uint16) external pure returns (uint128) {
        return MAX_BATCH_GAS;
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

    /// @dev Source-restricted messages are `0xFE ++ bytes2(requiredSource) ++ ...`; encoded in the message
    ///      because the interface pins this `pure`. Anything else returns 0 = any source permitted.
    bytes1 public constant SOURCE_RESTRICTED_MAGIC = 0xFE;

    function messageSourceCentrifugeId(bytes calldata message) external pure returns (uint16) {
        if (message.length >= 3 && message[0] == SOURCE_RESTRICTED_MAGIC) {
            return uint16(bytes2(message[1:3]));
        }
        return 0;
    }

    function messageFailureGasReserve() external pure returns (uint128) {
        return FAILURE_GAS_RESERVE;
    }
}
