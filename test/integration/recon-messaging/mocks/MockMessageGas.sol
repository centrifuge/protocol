// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IMessageGas} from "../../../../src/core/messaging/interfaces/IMessageGas.sol";

/// @dev Gas values only; the framing view lives on CountingProcessor.
contract MockMessageGas is IMessageGas {
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

    function messageFailureGasReserve() external pure returns (uint128) {
        return FAILURE_GAS_RESERVE;
    }
}
