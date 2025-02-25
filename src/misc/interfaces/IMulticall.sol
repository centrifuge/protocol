// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Allows to call several calls of the same contract in a single transaction
interface IMulticall {
    error CallFailed();
    error UnauthorizedSender();
    error AlreadyInitiated();

    /// @notice Execute a generic multicall.
    /// If one call fails, it reverts the whole transaction.
    /// @notice data An array of encoded methods of the same contract.
    function multicall(bytes[] calldata data) external payable;
}
