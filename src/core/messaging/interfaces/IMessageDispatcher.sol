// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IGateway} from "./IGateway.sol";
import {IMultiAdapter} from "./IMultiAdapter.sol";
import {IScheduleAuth} from "./IScheduleAuth.sol";
import {ITokenRecoverer} from "./ITokenRecoverer.sol";
import {ISpokeMessageSender, IHubMessageSender, IScheduleAuthMessageSender} from "./IGatewaySenders.sol";
import {
    ISpokeGatewayHandler,
    IBalanceSheetGatewayHandler,
    IHubGatewayHandler,
    IContractUpdateGatewayHandler,
    IVaultRegistryGatewayHandler
} from "./IGatewayHandlers.sol";

interface IMessageDispatcher is IScheduleAuthMessageSender, ISpokeMessageSender, IHubMessageSender {
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 indexed what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when an account is not valid to withdraw funds
    error CannotRefund();

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Routes and batches cross-chain messages between hub and spoke
    function gateway() external view returns (IGateway);

    /// @notice Handles multi-protocol message verification and routing for cross-chain communication
    function multiAdapter() external view returns (IMultiAdapter);

    /// @notice Processes timelocked rely/deny operations received from remote chains
    function scheduleAuth() external view returns (IScheduleAuth);

    /// @notice Hub-side handler for investment request processing and share issuance
    function hubHandler() external view returns (IHubGatewayHandler);

    /// @notice Recovers tokens mistakenly sent to protocol contracts
    function tokenRecoverer() external view returns (ITokenRecoverer);

    /// @notice Spoke-side handler for share and asset balance mutations
    function balanceSheet() external view returns (IBalanceSheetGatewayHandler);

    /// @notice Spoke-side handler for vault deployment and linking
    function vaultRegistry() external view returns (IVaultRegistryGatewayHandler);

    /// @notice Spoke-side handler for trusted contract reference updates
    function contractUpdater() external view returns (IContractUpdateGatewayHandler);

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    ///         Accepts a `bytes32` representation of 'hubRegistry' string value.
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;
}
