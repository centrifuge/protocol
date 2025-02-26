// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Allows to call several calls of the same contract in a single transaction
interface IMulticall {
    /// @notice Dispatched when an internal error has ocurred
    error CallFailed();

    /// @notice Dispatched when there is a re-entrancy issue
    error UnauthorizedSender();

    /// @notice Dispatched when multicall is called inside of one protected method or recursively
    error AlreadyInitiated();

    /// @notice Allows caller to execute multiple (batched) messages calls in one transaction.
    /// @param data An array of encoded methods of the same contract.
    /// @dev No reentrant execution is allowed.
    /// If one call fails, it reverts the whole transaction.
    /// In order to provide the correct value for functions that require top up,
    /// the caller must estimate separately, in advance, how much each of the message call will cost.
    /// The `msg.value` when calling this method must be the sum of all estimates.
    function multicall(bytes[] calldata data) external payable;
}
