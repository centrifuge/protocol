// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

interface IUpdateContract {
    error UnknownUpdateContractType();

    /// @notice Triggers an update on the target contract.
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  payload The payload to be processed by the target address
    function update(uint64 poolId, bytes16 scId, bytes calldata payload) external;
}
