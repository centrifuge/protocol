// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {IHub} from "../../../core/hub/interfaces/IHub.sol";

interface IManifest {
    /// @notice Validate whether a Hub call should proceed, and return the timelock duration.
    ///         Revert to block the call. Return 0 for immediate execution.
    /// @dev    Not marked `view` because implementations may need state reads or side effects.
    ///         The manifest is immutable per Supervisor, so the operator cannot swap it to bypass checks.
    ///         Implementations must return consistent values for the same calldata, otherwise an
    ///         operation submitted with one timelock could become unexecutable if the manifest later
    ///         returns a different value.
    /// @param poolId The pool being operated on.
    /// @param caller The address that initiated the call through the Supervisor.
    /// @param data The full calldata being forwarded to the Hub.
    /// @return timelock Seconds the operation must wait before execution. 0 = immediate.
    function check(PoolId poolId, address caller, bytes calldata data) external returns (uint48 timelock);
}

struct SupervisorConfig {
    bytes4[] hookSelectors;
    uint48 sentinelTimelock;
    uint48 expiryWindow;
    IManifest manifest;
}

interface ISupervisor {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event Submit(bytes32 indexed operationId, bytes4 indexed selector, uint48 executeAfter, bytes data);
    event Cancel(bytes32 indexed operationId);
    event Execute(bytes32 indexed operationId);
    event AddSentinel(address indexed sentinel);
    event RemoveSentinel(address indexed sentinel);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error NotOperatorOrSentinel();
    error NotOperator();
    error TimelockNotReady(uint48 executeAfter);
    error TimelockExpired();
    error OperationAlreadyPending();
    error OperationNotPending();
    error NotSentinel();
    error AlreadySentinel();
    error ZeroAddress();
    error CannotSelfCancel();
    error MulticallForbidden();
    error NotHooked();
    error ManifestRequired();

    //----------------------------------------------------------------------------------------------
    // Execution
    //----------------------------------------------------------------------------------------------

    /// @notice Execute a Hub call. For hooked selectors, the manifest determines the timelock:
    ///         if 0, executes immediately; if > 0, must have been submitted first.
    ///         Non-hooked selectors are forwarded directly.
    /// @param data The calldata to forward to the Hub.
    function execute(bytes calldata data) external payable;

    /// @notice Submit an operation for future execution. The manifest determines the timelock
    ///         duration for Hub calls. Sentinel management uses a fixed sentinelTimelock.
    ///         Expired operations must be canceled before the same calldata can be re-submitted.
    /// @param data The calldata for the timelocked operation.
    function submit(bytes calldata data) external;

    /// @notice Cancel a pending timelocked operation. Callable by the operator or sentinels.
    ///         A sentinel can only cancel their own removal if they are the sole sentinel.
    /// @param data The pending calldata to cancel.
    function cancel(bytes calldata data) external;

    //----------------------------------------------------------------------------------------------
    // Sentinel management
    //----------------------------------------------------------------------------------------------

    /// @notice Add a sentinel. Always timelocked with sentinelTimelock.
    ///         Flow: `submit(abi.encodeCall(addSentinel, (sentinel)))` → wait → `addSentinel(sentinel)`.
    /// @param sentinel The address to add as sentinel.
    function addSentinel(address sentinel) external;

    /// @notice Remove a sentinel. Always timelocked with sentinelTimelock.
    ///         Flow: `submit(abi.encodeCall(removeSentinel, (sentinel)))` → wait → `removeSentinel(sentinel)`.
    /// @param sentinel The address to remove as sentinel.
    function removeSentinel(address sentinel) external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    function hub() external view returns (IHub);
    function poolId() external view returns (PoolId);
    function operator() external view returns (address);
    function sentinelTimelock() external view returns (uint48);
    function expiryWindow() external view returns (uint48);
    function manifest() external view returns (IManifest);
    function hooked(bytes4 selector) external view returns (bool);
    function sentinels(address who) external view returns (bool);
    function sentinelCount() external view returns (uint256);
    function pending(bytes calldata data) external view returns (uint48);
}

interface ISupervisorFactory {
    event DeploySupervisor(PoolId indexed poolId, address indexed supervisor);

    function hub() external view returns (IHub);

    function newSupervisor(PoolId poolId, address operator, SupervisorConfig calldata config)
        external
        returns (ISupervisor);
}
