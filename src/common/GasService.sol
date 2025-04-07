// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";
import {MessageLib, MessageType} from "src/common/libraries/MessageLib.sol";
import {IMessageProperties} from "src/common/interfaces/IMessageProperties.sol";
import {PoolId} from "src/common/types/PoolId.sol";

/// @title  GasService
/// @notice This is a utility contract used to determine the execution gas limit
///         for a payload being sent across all supported adapters.
contract GasService is IGasService {
    using MessageLib for *;

    uint64 public immutable proofGasLimit;
    uint64 public immutable messageGasLimit;

    constructor(uint64 messageGasLimit_, uint64 proofGasLimit_) {
        messageGasLimit = messageGasLimit_;
        proofGasLimit = proofGasLimit_;
    }

    /// @inheritdoc IGasService
    function gasLimit(uint16, bytes calldata message) public view returns (uint64) {
        if (message.messageCode() == uint8(MessageType.MessageProof)) {
            return proofGasLimit;
        } else {
            return messageGasLimit;
        }
    }
}
