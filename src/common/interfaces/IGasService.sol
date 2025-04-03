// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";

interface IGasService {
    event File(bytes32 indexed what, uint64 value);

    error FileUnrecognizedParam();
    error DefaultGasLimitNotDefined();

    /// @notice Using file patter to update state variables;
    /// @dev    Used to update the messageGasLimit and proofGasLimit;
    ///         It is used in occasions where update is done rarely.
    function file(bytes32 what, uint16 chainId, uint8 messageCode, uint64 value) external;

    /// @notice The cost of 'message' execution on the recipient chain for an specific message.
    /// @param chainId Where to the cost is defined
    /// @param messageCode The code of the message to get the gas limit
    /// @return Amount in gas
    function messageGasLimit(uint16 chainId, uint8 messageCode) external view returns (uint64);

    /// @notice Gas limit for the execution cost of an individual message in a remote chain.
    /// @param chainId Where to the cost is defined
    /// @param  payload Individual message
    /// @return Estimated cost in WEI units
    function gasLimit(uint16 chainId, bytes calldata payload) external view returns (uint64);
}
