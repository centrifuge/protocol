// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";
import {IMessageProperties} from "src/common/interfaces/IMessageProperties.sol";
import {PoolId} from "src/common/types/PoolId.sol";

/// @title  GasService
/// @notice This is a utility contract used to determine the execution gas limit
///         for a payload being sent across all supported adapters.
contract GasService is IGasService {
    uint64 public immutable messageGasLimit;

    constructor(uint64 messageGasLimit_) {
        messageGasLimit = messageGasLimit_;
    }

    /// @inheritdoc IGasService
    function gasLimit(uint16, bytes calldata) public view returns (uint64) {
        // NOTE: In the future we could want to dispatch:
        // - by destination chain (for non-EVM chains)
        // - by message type
        // - by inspecting the payload checking different subsmessages that alter the endpoint processing
        return messageGasLimit;
    }
}
