// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

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
