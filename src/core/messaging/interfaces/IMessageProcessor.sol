// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IGateway} from "./IGateway.sol";
import {IMultiAdapter} from "./IMultiAdapter.sol";
import {IScheduleAuth} from "./IScheduleAuth.sol";
import {IMessageHandler} from "./IMessageHandler.sol";
import {ITokenRecoverer} from "./ITokenRecoverer.sol";
import {
    ISpokeGatewayHandler,
    IBalanceSheetGatewayHandler,
    IHubGatewayHandler,
    IContractUpdateGatewayHandler,
    IVaultRegistryGatewayHandler
} from "./IGatewayHandlers.sol";

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

    /// @notice Dispatched when a message is tried to send from a different chain than mainnet
    error OnlyFromMainnet();

    /// @notice Dispatched when a message is tried to send from a chain that is not the source
    error OnlyFromSource();

    /// @notice Dispatched when an invalid message is trying to handle
    error InvalidMessage(uint8 code);

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Routes and batches cross-chain messages between hub and spoke
    function gateway() external view returns (IGateway);

    /// @notice Handles multi-protocol message verification and routing for cross-chain communication
    function multiAdapter() external view returns (IMultiAdapter);

    /// @notice Hub-side handler for investment request processing and share issuance
    function hubHandler() external view returns (IHubGatewayHandler);

    /// @notice Recovers tokens mistakenly sent to protocol contracts
    function tokenRecoverer() external view returns (ITokenRecoverer);

    /// @notice Processes timelocked rely/deny operations received from remote chains
    function scheduleAuth() external view returns (IScheduleAuth);

    /// @notice Spoke-side handler for share and asset balance mutations
    function balanceSheet() external view returns (IBalanceSheetGatewayHandler);

    /// @notice Spoke-side handler for vault deployment and linking
    function vaultRegistry() external view returns (IVaultRegistryGatewayHandler);

    /// @notice Spoke-side handler for trusted contract reference updates
    function contractUpdater() external view returns (IContractUpdateGatewayHandler);

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Name of the parameter to update (accepts 'hubRegistry')
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;
}
