// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IUpdateContract {

    /// @notice Triggers an update on the target contract.
    /// @param  poolId The centrifuge pool id
    /// @param  trancheId The tranche id
    /// @param  payload The payload to be processed by the target address
    function update(uint64 poolId, bytes16 trancheId, bytes calldata payload) external;
}
