// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Allows to call several calls in the same transactions
interface IMulticall {
    /// @notice Identify a call method.
    struct Call {
        /// @notice Contract from where to perform the call
        address target;
        /// @notice Encoding of selector + parameters of the method
        bytes data;
    }

    /// @notice Execute a generic multicall.
    /// If one call fails, it reverts the whole transaction.
    function aggregate(Call[] calldata calls) external returns (bytes[] memory results);
}
