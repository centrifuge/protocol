// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0;

/// Interface for contracts that requires a `file()` methods in order to update properties
interface IFile {
    /// Emit when the `what` parameter of `file()` is not supported by the implementation.
    error UnrecognizedWhatParam();

    /// @notice Emit when a call to `file()` was performed.
    event Filed(bytes32 what, address addr);

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// @param data New value given to the `what` parameter.
    function file(bytes32 what, address data) external;
}
