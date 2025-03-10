// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";

/// @notice Interface for dispatch-only gateway
interface IGateway is IMessageHandler, IMessageSender {
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 indexed what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedWhat();

    error NoBatched();

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'adapter' or 'handler' string values.
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;

    /// @notice Set the payable source of the message.
    /// @param  source Used to determine whether it is eligible for TX cost payment.
    function setPayableSource(address source) external;

    /// @notice Initialize batching message
    function startBatch() external;

    /// @notice Finalize batching messages and send the resulting batch message
    function endBatch() external;

    /// @notice Cancel the recovery of a message.
    /// @param  adapter Adapter that the recovery was targeting
    /// @param  messageHash Hash of the message being disputed
    function disputeMessageRecovery(address adapter, bytes32 messageHash) external;
}
