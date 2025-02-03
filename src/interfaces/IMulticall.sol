// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Allows to call several calls in the same transactions
interface IMulticall {
    struct Call {
        address target;
        bytes data;
    }

    /// @notice Execute a generic multicall.
    /// If one call fails, it reverts the whole transaction.
    function aggregate(Call[] calldata calls) external returns (bytes[] memory results);
}
