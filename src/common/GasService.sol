// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";
import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";

/// @title  GasService
/// @notice This is a utility contract used to determine the execution gas limit
///         for a payload being sent across all supported adapters.
contract GasService is IGasService, Auth {
    using MessageLib for *;

    /// @inheritdoc IGasService
    uint64 public proofGasLimit;

    /// @inheritdoc IGasService
    uint64 public messageGasLimit;

    constructor(uint64 messageGasLimit_, uint64 proofGasLimit_) Auth(msg.sender) {
        messageGasLimit = messageGasLimit_;
        proofGasLimit = proofGasLimit_;
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
    function estimate(uint32, /*chainId*/ bytes calldata payload) public view returns (uint256) {
        uint8 code = payload.messageCode();
        if (code == uint8(MessageType.MessageProof)) {
            return proofGasLimit;
        } else {
            return messageGasLimit;
        }
    }

    /// @inheritdoc IGasService
    function shouldRefuel(address source, bytes calldata) public pure returns (bool success) {
        return source != address(0);
    }
}
