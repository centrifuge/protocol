// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

interface IAdapter is IAuth {
    error NotGateway();
    error UnknownChainId();

    /// @notice Send a payload to the destination chain
    function send(uint16 centrifugeChainId, bytes calldata payload, uint256 gasLimit, address refund)
        external
        payable;

    /// @notice Estimate the total cost in native gas tokens
    function estimate(uint16 centrifugeChainId, bytes calldata payload, uint256 gasLimit)
        external
        view
        returns (uint256);
}
