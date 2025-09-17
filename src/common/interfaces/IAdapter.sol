// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAuth} from "../../misc/interfaces/IAuth.sol";

interface IAdapter is IAuth {
    error NotEntrypoint();
    error UnknownChainId();

    /// @notice Send a payload to the destination chain
    function send(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit, address refund)
        external
        payable
        returns (bytes32 adapterData);

    /// @notice Estimate the total cost in native gas tokens
    function estimate(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit) external view returns (uint256);
}
