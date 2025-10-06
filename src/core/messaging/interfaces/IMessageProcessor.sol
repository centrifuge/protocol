// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMessageHandler} from "../../interfaces/IMessageHandler.sol";
import {IMessageProperties} from "../../interfaces/IMessageProperties.sol";

interface IMessageProcessor is IMessageHandler, IMessageProperties {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event File(bytes32 indexed what, address addr);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error InvalidSourceChain();

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when a message is tried to send from a different chain than mainnet
    error OnlyFromMainnet();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Name of the parameter to update (accepts 'hubRegistry')
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;
}
