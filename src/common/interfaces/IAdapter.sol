// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IAdapter {
    error NotGateway();
    error UnknownChainId();

    /// @notice Send a payload to the destination chain
    function send(uint32 chainId, bytes calldata payload, uint256 gasLimit, address refund) external payable;

    /// @notice Estimate the total cost in native gas tokens
    function estimate(uint32 chainId, bytes calldata payload, uint256 gasLimit) external view returns (uint256);
}
