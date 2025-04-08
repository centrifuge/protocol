// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IMessageProperties} from "src/common/interfaces/IMessageProperties.sol";

interface IMessageProcessor is IMessageHandler, IMessageProperties {
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 indexed what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'hubRegistry' string value.
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;
}
