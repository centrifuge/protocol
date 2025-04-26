// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGasService} from "src/common/interfaces/IGasService.sol";

/// @title  GasService
/// @notice This is a utility contract used to determine the execution gas limit
///         for a payload being sent across all supported adapters.
contract GasService is IGasService {
    uint128 internal immutable _maxBatchSize;
    uint128 internal immutable _messageGasLimit;

    constructor(uint128 maxBatchSize_, uint128 messageGasLimit) {
        _maxBatchSize = maxBatchSize_;
        _messageGasLimit = messageGasLimit;
    }

    /// @inheritdoc IGasService
    function maxBatchSize(uint16) public view returns (uint128) {
        return _maxBatchSize;
    }

    /// @inheritdoc IGasService
    function gasLimit(uint16, bytes calldata) public view returns (uint128) {
        return _messageGasLimit;
    }
}
