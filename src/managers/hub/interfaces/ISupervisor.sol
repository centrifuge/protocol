// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IHub} from "../../../core/hub/interfaces/IHub.sol";
import {PoolId} from "../../../core/types/PoolId.sol";

interface IManifest {
    /// @notice Validate whether a Hub call should proceed.
    /// @param poolId The pool being operated on.
    /// @param caller The address that initiated the call through the Supervisor.
    /// @param data The full calldata being forwarded to the Hub.
    /// @return True if the call is allowed.
    function check(PoolId poolId, address caller, bytes calldata data) external returns (bool);
}

interface ISupervisor {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event Submit(bytes32 indexed operationId, bytes4 indexed selector, uint48 executeAfter);
    event Cancel(bytes32 indexed operationId);
    event Execute(bytes32 indexed operationId);
    event AddGuardian(address indexed guardian);
    event RemoveGuardian(address indexed guardian);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error NotManagerOrGuardian();
    error NotManager();
    error TimelockNotSet();
    error TimelockNotReady(uint48 executeAfter);
    error TimelockExpired();
    error OperationAlreadyPending();
    error OperationNotPending();
    error ManifestCheckFailed();
    error NotGuardian();
    error AlreadyGuardian();
    error ZeroAddress();
    error ForwardFailed();

    //----------------------------------------------------------------------------------------------
    // Execution
    //----------------------------------------------------------------------------------------------

    /// @notice Execute a Hub call. If the function has a timelock, it must have been submitted first.
    ///         If no timelock is set, the call is forwarded immediately.
    /// @param data The calldata to forward to the Hub.
    function execute(bytes calldata data) external payable;

    /// @notice Submit a timelocked operation for future execution.
    /// @param data The calldata to forward to the Hub.
    /// @return operationId The unique identifier for this pending operation.
    function submit(bytes calldata data) external returns (bytes32 operationId);

    /// @notice Cancel a pending timelocked operation. Callable by pool managers or guardians.
    /// @param operationId The operation to cancel.
    function cancel(bytes32 operationId) external;

    //----------------------------------------------------------------------------------------------
    // Guardian management
    //----------------------------------------------------------------------------------------------

    /// @notice Add a guardian. Callable by pool managers. Immediate, no timelock.
    /// @param guardian The address to add as guardian.
    function addGuardian(address guardian) external;

    /// @notice Remove a guardian. Callable by pool managers. Always timelocked.
    ///         Must be submitted first via submit(), then executed after the delay.
    /// @param guardian The address to remove as guardian.
    function removeGuardian(address guardian) external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    function hub() external view returns (IHub);
    function poolId() external view returns (PoolId);
    function delay() external view returns (uint48);
    function expiryWindow() external view returns (uint48);
    function manifest() external view returns (IManifest);
    function timelocked(bytes4 selector) external view returns (bool);
    function hooked(bytes4 selector) external view returns (bool);
    function guardians(address who) external view returns (bool);
    function pending(bytes32 operationId) external view returns (uint48);
}

interface ISupervisorFactory {
    event DeploySupervisor(PoolId indexed poolId, address indexed supervisor);

    function hub() external view returns (IHub);

    function newSupervisor(
        PoolId poolId,
        bytes4[] calldata timelockSelectors,
        bytes4[] calldata hookSelectors,
        uint48 delay,
        uint48 expiryWindow,
        IManifest hook
    ) external returns (ISupervisor);
}
