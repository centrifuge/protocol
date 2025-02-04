// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";

/// @notice Abstract the mechanism to unlock pools
interface IPoolLocker {
    /// @notice Dispatched when the pool is already unlocked.
    /// It means when calling to `execute()` inside `execute()`.
    error PoolAlreadyUnlocked();

    /// @notice Dispatched when the `targets` and `datas` length parameters in `execute()` do not matched.
    error WrongExecutionParams();

    /// @notice Dispatched when the pool is not unlocked to interact with.
    error PoolLocked();

    /// @notice Execute a multicall inside of an unlocked pool.
    function execute(PoolId poolId, IMulticall.Call[] calldata calls) external returns (bytes[] memory results);

    /// @notice Returns the unlocked poolId.
    /// In only will contain a non-zero value if called inside `execute()`
    function unlockedPoolId() external view returns (PoolId);
}
