// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IGateway} from "./IGateway.sol";
import {IMultiAdapter} from "./IMultiAdapter.sol";
import {IScheduleAuth} from "./IScheduleAuth.sol";
import {ISpokeGatewayHandler, IHubGatewayHandler} from "./IGatewayHandlers.sol";
import {ISpokeMessageSender, IHubMessageSender, IScheduleAuthMessageSender} from "./IGatewaySenders.sol";

import {IEnvoy} from "../../utils/interfaces/IEnvoy.sol";

interface IMessageDispatcher is IScheduleAuthMessageSender, ISpokeMessageSender, IHubMessageSender {
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 indexed what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when an unsupported manager kind is dispatched locally
    error InvalidManagerKind();

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice The chain identifier of the local Centrifuge chain
    function localCentrifugeId() external view returns (uint16);

    /// @notice Routes and batches cross-chain messages between hub and spoke
    function gateway() external view returns (IGateway);

    /// @notice Handles multi-protocol message verification and routing for cross-chain communication
    function multiAdapter() external view returns (IMultiAdapter);

    /// @notice Processes administrative cross-chain messages for pool, share class, and vault operations
    function spokeHandler() external view returns (ISpokeGatewayHandler);

    /// @notice Processes timelocked rely/deny operations received from remote chains
    function scheduleAuth() external view returns (IScheduleAuth);

    /// @notice Hub-side handler for investment request processing and share issuance
    function hubHandler() external view returns (IHubGatewayHandler);

    /// @notice Hub-side dispatcher for the payable `IManagerCallFromHub` path
    function envoy() external view returns (IEnvoy);

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update
    ///         (accepts 'envoy', 'gateway', 'multiAdapter', 'spokeHandler', 'hubHandler')
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;
}
