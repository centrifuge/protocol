// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISpokeMessageSender, IHubMessageSender, IRootMessageSender} from "./IGatewaySenders.sol";

interface IMessageDispatcher is IRootMessageSender, ISpokeMessageSender, IHubMessageSender {
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 indexed what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when a there is not enough gas to pay for message.
    error NotEnoughGasToSendMessage();

    /// @notice Dispatched when the message can not be batched
    error CannotBeBatched();

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'hubRegistry' string value.
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;
}
