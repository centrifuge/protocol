// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IAdapter {
    // --- Outgoing ---
    /// @notice Send a payload to Centrifuge Chain
    function send(bytes calldata payload) external;

    /// @notice Estimate the total cost in native gas tokens
    function estimate(bytes calldata payload, uint256 baseCost) external view returns (uint256);

    /// @notice Pay the gas cost
    function pay(bytes calldata payload, address refund) external payable;
}
