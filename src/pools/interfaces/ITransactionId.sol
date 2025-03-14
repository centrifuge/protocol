// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/pools/types/PoolId.sol";

interface ITransactionId {
    /// @notice gets the current transaction id
    function transactionId() external returns (bytes32);

    /// @notice generates a new transaction id for the given pool
    function generateTransactionId(PoolId poolId) external returns (bytes32);
}
