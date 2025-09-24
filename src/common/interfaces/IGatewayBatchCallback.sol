// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @notice Contract that offers an utility for calling a method that will be batched
interface IGatewayBatchCallback {
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 indexed what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when withBatch is called but the system is already batching
    ///         (it's inside of another withBatch level)
    error AlreadyBatching();

    /// @notice Dispatched when the callback fails with no error
    error CallFailedWithEmptyRevert();

    /// @notice Updates a contract parameter.
    /// @param  what Name of the parameter to update.
    ///         Accepts a `bytes32` representation of 'gateway' string value.
    /// @param  data New value given to the `what` parameter
    function file(bytes32 what, address data) external;

    /// @notice Calls a method that should be in the same contract as the caller, as a callback.
    ///         The method called will be wrapped inside startBatching and endBatching,
    ///         so any method call inside that requires messaging will be batched.
    /// @param  data encoding data for the callback method
    /// @return cost the total cost of the batch sent
    function withBatch(bytes memory data) external payable returns (uint256 cost);
}
