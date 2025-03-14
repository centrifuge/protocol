// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";

interface IAdapter is IMessageSender {
    error NotGateway();

    /// @notice Send a payload to Centrifuge Chain
    /// @notice Send a payload to the destination chain
    function send(uint32 chainId, bytes calldata payload) external;

    /// @notice Estimate the total cost in native gas tokens
    function estimate(uint32 chainId, bytes calldata payload, uint256 baseCost) external view returns (uint256);

    /// @notice Pay the gas cost
    function pay(uint32 chainId, bytes calldata payload, address refund) external payable;
}
