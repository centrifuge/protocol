// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IMessageProperties} from "../../../../src/core/messaging/interfaces/IMessageProperties.sol";
import {PoolId} from "../../../../src/core/types/PoolId.sol";

/// @dev Treats every payload as a single-message batch of length payload.length.
///      All messages belong to GLOBAL_POOL (PoolId(0)).
contract MockMessageProperties is IMessageProperties {
    /// @dev Must exceed PROCESS_FAIL_MESSAGE_GAS (35_000) to allow excessivelySafeCall headroom
    uint128 public constant PROCESSING_GAS_LIMIT = 200_000;
    uint128 public constant MAX_BATCH_GAS = 10_000_000;

    function messageOverallGasLimit(uint16, bytes calldata) external pure returns (uint128) {
        return 0;
    }

    function messageProcessingGasLimit(uint16, bytes calldata) external pure returns (uint128) {
        return PROCESSING_GAS_LIMIT;
    }

    function maxBatchGasLimit(uint16) external pure returns (uint128) {
        return MAX_BATCH_GAS;
    }

    /// @dev Single-message batches: the entire payload is one message
    function messageLength(bytes calldata message) external pure returns (uint16) {
        return uint16(message.length);
    }

    function messagePoolId(bytes calldata) external pure returns (PoolId) {
        return PoolId.wrap(0); // GLOBAL_POOL
    }
}
