// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @notice Cross-chain transport used by `MultiAdapter` to carry protocol payloads between chains.
/// @dev    Implementations MUST NOT revert in `send` or `estimate` for a route they are configured for.
///         `MultiAdapter` fans every outgoing payload out over the whole active adapter set and bubbles any
///         revert, and `Gateway` estimates before it dispatches, so one failing adapter vetoes all outbound
///         traffic of the pools that configure it, even when the remaining adapters would satisfy the
///         threshold on their own. Adapters placed after the failing one are never reached either, so a
///         `StandbyAdapter` does not get to record its send, and nothing is queued for later repayment since
///         the revert precedes the underpaid bookkeeping. Rotating away from such an adapter cannot go
///         through the hub, which would send over the same broken set: see {IMultiAdapter-setAdapters} for
///         the recovery runbook.
interface IAdapter {
    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error NotEntrypoint();
    error UnknownChainId();

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @notice Send a payload to the destination chain
    /// @param centrifugeId The destination chain ID
    /// @param payload The message payload to send
    /// @param gasLimit The gas limit for execution on the destination chain
    /// @param refund The address to receive any excess payment refund
    /// @return adapterData Adapter-specific data returned from the send operation
    function send(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit, address refund)
        external
        payable
        returns (bytes32 adapterData);

    /// @notice Estimate the total cost in native gas tokens
    /// @param centrifugeId The destination chain ID
    /// @param payload The message payload to send
    /// @param gasLimit The gas limit for execution on the destination chain
    /// @return The estimated cost in native gas tokens
    function estimate(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit) external view returns (uint256);
}
