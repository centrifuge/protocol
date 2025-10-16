// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGateway} from "./IGateway.sol";

/// @title  ICrosschainBatcher
/// @notice Helper contract for batching multiple crosschain messages into a single transaction
///
///         This contract wraps the Gateway's batching functionality, allowing users to execute
///         multiple message sends in a single atomic operation. The contract handles starting
///         and ending the batch, ensuring all messages are sent together or the transaction reverts.
interface ICrosschainBatcher {
    // Events
    /// @notice Emitted when a contract parameter is updated
    /// @param  what The parameter that was updated
    /// @param  data The new value for the parameter
    event File(bytes32 indexed what, address data);

    // Errors
    error NotEnoughValueForCallback();
    error CallFailedWithEmptyRevert();
    error CallbackWasNotLocked();
    error CallbackAlreadyLocked();
    error CallbackNotFromSender();
    error FileUnrecognizedParam();

    // State variables
    /// @notice Returns the gateway contract used for message batching
    /// @return The gateway contract instance
    function gateway() external view returns (IGateway);

    // Methods
    /// @notice Update contract dependencies
    /// @param  what The parameter to update
    /// @param  data The new value for the parameter
    function file(bytes32 what, address data) external;

    /// @notice Locks the callback to ensure it's called exactly once within withBatch
    /// @dev    Must be called from within the callback executed by withBatch
    ///         This ensures the callback is executed in the correct context
    function lockCallback() external;

    /// @notice Execute a callback function within a batching context
    /// @dev    The callback function should make multiple calls to gateway.send() which will be batched.
    ///         The callback MUST call gateway.lockCallback() before returning to signal completion.
    /// @param  data The calldata to execute on msg.sender
    /// @param  value The amount of ETH to forward with the callback
    /// @param  refund The address to refund excess ETH to
    function withBatch(bytes memory data, uint256 value, address refund) external payable;

    /// @notice Execute a callback function within a batching context (without callback value)
    /// @dev    Convenience function that calls withBatch with value = 0
    /// @param  data The calldata to execute on msg.sender
    /// @param  refund The address to refund excess ETH to
    function withBatch(bytes memory data, address refund) external payable;
}
