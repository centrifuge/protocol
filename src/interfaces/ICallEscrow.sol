// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Allows to pass a generic call to be called from this contract
interface ICallEscrow {
    /// @notice Perform the call passed by parameter.
    /// @param target contract where to perform the call
    /// @param data encoded selector + parameters of the call
    function call(address target, bytes calldata data) external returns (bool success, bytes memory results);
}
