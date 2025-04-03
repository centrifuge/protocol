// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";
import {IMessageProperties} from "src/common/interfaces/IMessageProperties.sol";
import {PoolId} from "src/common/types/PoolId.sol";

/// @title  GasService
/// @notice This is a utility contract used to determine the execution gas limit
///         for a payload being sent across all supported adapters.
contract GasService is IGasService, Auth {
    /// @inheritdoc IGasService
    uint64 public proofGasLimit;

    /// @inheritdoc IGasService
    uint64 public messageGasLimit;

    IMessageProperties public messageProperties;

    constructor(uint64 messageGasLimit_, uint64 proofGasLimit_, IMessageProperties messageProperties_)
        Auth(msg.sender)
    {
        messageGasLimit = messageGasLimit_;
        proofGasLimit = proofGasLimit_;
        messageProperties = messageProperties_;
    }

    /// @inheritdoc IGasService
    function file(bytes32 what, uint64 value) external auth {
        if (what == "messageGasLimit") messageGasLimit = value;
        else if (what == "proofGasLimit") proofGasLimit = value;
        else revert FileUnrecognizedParam();
        emit File(what, value);
    }

    /// --- Estimations ---
    /// @inheritdoc IGasService
    function estimate(uint16, bytes calldata payload) public view returns (uint256) {
        if (messageProperties.messageProofHash(payload) != bytes32(0)) {
            return proofGasLimit;
        } else {
            return messageGasLimit;
        }
    }
}
