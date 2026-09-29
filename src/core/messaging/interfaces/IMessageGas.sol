// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @notice Defines the gas properties of raw messages.
/// @dev    Values only: how a message is framed or attributed is `IMessageParser`, which is read from the
///         processor instead, so that filing this interface cannot alter source-chain authentication.
interface IMessageGas {
    /// @notice Gas limit for the execution cost of an individual message in a remote chain from the adapter.
    /// @dev    NOTE: In the future we could want to dispatch:
    ///         - by destination chain (for non-EVM chains)
    ///         - by message type
    ///         - by inspecting the payload checking different subsmessages that alter the endpoint processing
    /// @param centrifugeId Where to the cost is defined
    /// @param message Individual message
    /// @return Estimated cost in WEI units
    function messageOverallGasLimit(uint16 centrifugeId, bytes calldata message) external view returns (uint128);

    /// @notice Similar to messageOverallGasLimit but taking only into account the exact gas to process it from the Gateway
    ///         for processing the message without any extra addition
    function messageProcessingGasLimit(uint16 centrifugeId, bytes calldata message) external view returns (uint128);

    /// @notice Maximum Gas limit for a batch, determined how much the destination chain can process
    /// @param centrifugeId Destination where to the maximum cost is defined
    function maxBatchGasLimit(uint16 centrifugeId) external view returns (uint128);

    /// @notice Gas reserved in every message budget to handle a worst-case processor revert.
    function messageFailureGasReserve() external view returns (uint128);
}
