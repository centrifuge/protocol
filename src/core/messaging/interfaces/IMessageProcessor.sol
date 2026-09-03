// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IGateway} from "./IGateway.sol";
import {IMultiAdapter} from "./IMultiAdapter.sol";
import {IScheduleAuth} from "./IScheduleAuth.sol";
import {IMessageHandler} from "./IMessageHandler.sol";
import {ISpokeGatewayHandler, IHubGatewayHandler} from "./IGatewayHandlers.sol";

interface IMessageProcessor is IMessageHandler {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event File(bytes32 indexed what, address addr);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when an invalid message is trying to handle
    error InvalidMessage(uint8 code);

    /// @notice Dispatched when the manager kind in an `UpdateManager` message is not supported
    error InvalidManagerKind();

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Routes and batches cross-chain messages between hub and spoke
    function gateway() external view returns (IGateway);

    /// @notice Handles multi-protocol message verification and routing for cross-chain communication
    function multiAdapter() external view returns (IMultiAdapter);

    /// @notice Processes administrative cross-chain messages for pool, share class, and vault operations
    function spokeHandler() external view returns (ISpokeGatewayHandler);

    /// @notice Hub-side handler for investment request processing and share issuance
    function hubHandler() external view returns (IHubGatewayHandler);

    /// @notice Processes timelocked rely/deny operations received from remote chains
    function scheduleAuth() external view returns (IScheduleAuth);

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Name of the parameter to update
    ///         (accepts 'hubHandler', 'gateway', 'spokeHandler', 'multiAdapter', 'envoy')
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;
}
