// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {IHub} from "../../../core/hub/interfaces/IHub.sol";

interface IManifest {
    /// @notice Validate whether a Hub call should proceed, and return the timelock duration.
    ///         Revert to block the call. Return 0 for immediate execution.
    /// @param poolId The pool being operated on.
    /// @param caller The address that initiated the call through the Supervisor.
    /// @param data The full calldata being forwarded to the Hub.
    /// @return timelock Seconds the operation must wait before execution. 0 = immediate.
    function check(PoolId poolId, address caller, bytes calldata data) external returns (uint48 timelock);
}

enum TrustedCall {
    AddSentinel,
    RemoveSentinel
}

interface ISupervisor {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event AddSentinel(address indexed sentinel);
    event RemoveSentinel(address indexed sentinel);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error NotOperatorOrSentinel();
    error NotOperator();
    error NotSentinel();
    error AlreadySentinel();
    error ZeroAddress();
    error MulticallForbidden();
    error NotContractUpdater();
    error TimelockExpired();
    error LastSentinel();
    error CannotSelfCancel();

    //----------------------------------------------------------------------------------------------
    // Execution
    //----------------------------------------------------------------------------------------------

    /// @notice Execute a Hub call. The Hub's manifest handles timelocking: if the manifest returns
    ///         timelock > 0, the Hub auto-submits the operation as pending and the tx succeeds
    ///         without executing the operation immediately.
    /// @param data The calldata to forward to the Hub.
    function execute(bytes calldata data) external payable;

    /// @notice Execute a pending Hub operation after its timelock has passed.
    ///         Callable by operator or sentinels.
    /// @param data The original calldata that was auto-submitted by the Hub.
    function executePending(bytes calldata data) external payable;

    /// @notice Cancel a pending Hub operation. Callable by operator or sentinels.
    ///         A sentinel cannot cancel their own removal when multiple sentinels exist.
    /// @param data The original calldata that was auto-submitted by the Hub.
    function cancelPending(bytes calldata data) external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    function hub() external view returns (IHub);
    function poolId() external view returns (PoolId);
    function operator() external view returns (address);
    function contractUpdater() external view returns (address);
    function expiryWindow() external view returns (uint48);
    function sentinels(address who) external view returns (bool);
    function sentinelCount() external view returns (uint256);
}

interface ISupervisorFactory {
    event DeploySupervisor(PoolId indexed poolId, address indexed supervisor);

    function hub() external view returns (IHub);

    function newSupervisor(PoolId poolId, address operator, address contractUpdater, uint48 expiryWindow)
        external
        returns (ISupervisor);
}
