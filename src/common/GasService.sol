// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";
import {IMessageProperties} from "src/common/interfaces/IMessageProperties.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";

/// @title  GasService
/// @notice This is a utility contract used to determine the execution gas limit
///         for a payload being sent across all supported adapters.
contract GasService is IGasService, Auth {
    using BytesLib for bytes;

    /// @inheritdoc IGasService
    mapping(uint16 chainId => mapping(uint8 => uint64)) public messageGasLimit;

    constructor(uint64 globalDefaultGasValue) Auth(msg.sender) {
        messageGasLimit[0][0] = globalDefaultGasValue;
    }

    /// @inheritdoc IGasService
    function file(bytes32 what, uint16 chainId, uint8 messageCode, uint64 value) external auth {
        if (what == "messageGasLimit") messageGasLimit[chainId][messageCode] = value;
        else revert FileUnrecognizedParam();
        emit File(what, value);
    }

    /// --- Estimations ---
    /// @inheritdoc IGasService
    function gasLimit(uint16 chainId, bytes calldata payload) public view returns (uint64 gasLimit_) {
        uint8 messageCode = payload.toUint8(0);
        gasLimit_ = messageGasLimit[chainId][messageCode];

        if (gasLimit_ == 0) {
            // Use chain default gas value
            gasLimit_ = messageGasLimit[chainId][0];

            if (gasLimit_ == 0) {
                // Use global default gas value
                gasLimit_ = messageGasLimit[0][0];
            }
        }
    }
}
