// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {IHub} from "../../../core/hub/interfaces/IHub.sol";

interface IManifest {
    /// @notice Validate whether a Hub call should proceed, and return the timelock duration.
    ///         Revert to block the call. Return 0 for immediate execution.
    /// @dev    Called by the Hub itself from inside {IHub.propose}, once per call in the proposed
    ///         batch. Implementations should restrict `msg.sender` to the Hub address.
    /// @param poolId The pool being operated on.
    /// @param caller The address that initiated the propose call.
    /// @param data The Hub calldata being proposed.
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
    error NotContractUpdater();
    error TimelockExpired();
    error LastSentinel();
    error CannotSelfCancel();

    //----------------------------------------------------------------------------------------------
    // Execution
    //----------------------------------------------------------------------------------------------

    /// @notice Propose a batch of Hub manager calls. Operator only. Forwards to {IHub.propose},
    ///         which runs the pool's manifest over each call and either executes the batch
    ///         immediately (max timelock == 0) or stores it as pending.
    /// @param calls Array of Hub-targeted calldata. Each call's first argument must be `poolId`.
    /// @return opId The pending-operation id (zero when executed immediately).
    function propose(bytes[] calldata calls) external payable returns (bytes32 opId);

    /// @notice Execute a pending Hub batch after its timelock has passed.
    ///         Callable by operator or sentinels. Reverts if the expiry window has passed.
    /// @param calls The exact batch passed to {propose}.
    function execute(bytes[] calldata calls) external payable;

    /// @notice Cancel a pending Hub batch. Callable by operator or sentinels.
    ///         A sentinel cannot cancel their own removal when multiple sentinels exist —
    ///         if any call in the batch is a sentinel-self-removal it reverts.
    /// @param calls The exact batch passed to {propose}.
    function cancel(bytes[] calldata calls) external;

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
