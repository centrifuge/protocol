// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {IHub} from "../../../core/hub/interfaces/IHub.sol";
import {IManifest} from "../../../core/hub/interfaces/IManifest.sol";

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

    /// @notice Submit a batch of Hub manager calls. Operator only. Forwards to {IHub.await},
    ///         which always queues the batch. Use {execute} (or {awaitAndExecute}) to run it.
    /// @param calls    Array of Hub-targeted calldata. Each call's first argument must be `poolId`.
    /// @param callback Optional callback payload invoked on the submitter after execute runs.
    function await(bytes[] calldata calls, bytes calldata callback) external returns (uint64 nonce, bytes32 opId);

    /// @notice {await} + {execute} in one transaction. Operator only. Reverts if the manifest
    ///         imposes any timelock.
    function awaitAndExecute(bytes[] calldata calls, bytes calldata callback)
        external
        payable
        returns (uint64 nonce, bytes32 opId);

    /// @notice Execute a pending Hub batch after its timelock has passed.
    ///         Callable by operator or sentinels. Reverts if the expiry window has passed.
    function execute(uint64 nonce, bytes[] calldata calls, bytes calldata callback) external payable;

    /// @notice Cancel a pending Hub batch. Callable by operator or sentinels.
    ///         A sentinel cannot cancel their own removal when multiple sentinels exist —
    ///         if any call in the batch is a sentinel-self-removal it reverts.
    function cancel(uint64 nonce, bytes[] calldata calls, bytes calldata callback) external;

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
