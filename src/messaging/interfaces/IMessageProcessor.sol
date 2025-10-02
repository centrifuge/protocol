// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMessageHandler} from "../../core/interfaces/IMessageHandler.sol";

interface IMessageProcessor is IMessageHandler {
    error InvalidSourceChain();

    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 indexed what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when a message is tried to send from a different chain than mainnet
    error OnlyFromMainnet();

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'hubRegistry' string value.
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;
}
